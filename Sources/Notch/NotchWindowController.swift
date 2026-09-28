import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchWindowController {
    let model = NotchViewModel()
    var displayPreference: DisplayPreference = .followActiveWindow

    /// The panel's content view, so a test can check what SwiftUI is and is not
    /// allowed to reach.
    var panelContentViewForTesting: NSView? { panel?.contentView }

    /// What AppKit settled on, for tests that need to see the panel move and
    /// fade rather than take our word for it.
    var panelFrameForTesting: CGRect? { panel?.frame }
    var panelAlphaForTesting: CGFloat { panel?.alphaValue ?? 0 }

    /// Hooked up by the app delegate; drives the menu's "Refresh now".
    var onRefresh: (() -> Void)?
    /// One "Sign in to …" item per provider that needs a browser session.
    var signInItems: [(title: String, action: () -> Void)] = []
    /// Driven by the notch's own chrome.

    /// Refetch a single provider, asked for by clicking its ring.
    var onRefreshProvider: ((String) async -> Void)?
    /// Open the settings window, asked for by clicking the handle.
    var onOpenSettings: (() -> Void)?
    /// An ⌥-drag on the pill settled at a new `model.alongOffset`. The
    /// controller only holds the live value; persisting it per edge is
    /// Preferences' job, the same division `apply(edge:)` already keeps.
    var onReposition: ((CGFloat) -> Void)?
    /// A move settled on a new edge — and, carried there by an ⌥-drag, where
    /// along it it was let go, as that edge's offset; nil keeps the offset the
    /// edge remembers. The fleet owns writing that to preferences, for the
    /// same reason it owns `onReposition`.
    var onMoveToEdge: ((NotchEdge, CGFloat?) -> Void)?

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?

    /// The display this notch belongs to. Nil follows the menu-bar screen,
    /// which is what a single-controller setup did before the fleet existed —
    /// so leaving it unset changes nothing.
    var assignedScreen: NSScreen?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var clearHoverWork: DispatchWorkItem?
    private var clockTimer: Timer?
    private var cursorTimer: Timer?
    /// Full-screen state on its own, slower beat. See `startWatchingFullScreen`.
    private var fullScreenTimer: Timer?
    private var fullScreenFollowUp: DispatchWorkItem?
    static let fullScreenPollInterval: TimeInterval = 2

    /// Hover in is quick; hover out waits, because the pointer has to cross the
    /// gap between the notch and the card without the card vanishing under it.
    private let hoverGrace: TimeInterval = 0.25
    /// Longer than the hover grace: folding shut is a bigger movement than
    /// dismissing a tooltip, and doing it the instant the pointer strays feels
    /// twitchy rather than responsive.
    private let foldGrace: TimeInterval = 0.45
    private var foldWork: DispatchWorkItem? {
        didSet {
            // A fold that is not going to happen after all — pinned, peeked,
            // hovered again, dragged: the arcs that set off home come back out.
            if foldWork == nil, model.isExpanded, model.handlesTuckedAway {
                model.handlesTuckedAway = false
            }
        }
    }
    /// Folds the notch again after a peek, when nothing else is holding it open.
    private var peekWork: DispatchWorkItem?
    /// The session a peek is currently offering, and how long the offer lasts.
    ///
    /// A click on the open notch normally pins it or refetches a ring; while
    /// this is set and unexpired it jumps to the session instead. The expiry is
    /// what keeps the two apart — without it, the *next* click on the notch,
    /// minutes later and about something else, would still be raising a
    /// terminal window.
    private var pendingFocus: (pid: pid_t, until: Date)?
    /// When the current peek's five seconds are up.
    ///
    /// The hover fold has to be told to leave it alone until then. Without
    /// this the cursor poll — which runs every 0.3s and asks "is the pointer on
    /// the notch?", to which the answer during a peek is almost always no —
    /// scheduled a fold immediately, and the notch opened and shut inside a
    /// second. A peek is not the pointer arriving, so the pointer leaving is
    /// not what should end it.
    private var peekUntil: Date?
    /// The standing visibility choice, so a peek never overrides Hidden.
    private var visibility: NotchVisibility = .onHover
    /// Whether we have pushed the pointing hand onto the cursor stack.
    private var shownCursor: NSCursor?
    /// Where the pointer let go of the notch by its dots, while it has not
    /// moved since: the dots and the button stay out till it does.
    private var restingOnGrip: CGPoint?
    /// Option-drag moves the whole notch under the pointer. Hovering rings
    /// while that happens is accidental — the pointer necessarily crosses
    /// them as the panel follows it — so cursor tracking is suspended until
    /// the drag ends.
    private var isOptionDragging = false

    /// Determines whether a full-screen application window is active on this notch's display.
    /// Default implementation queries WindowServer and NSWorkspace; overridable for testing.
    lazy var isFullScreenActive: () -> Bool = { [weak self] in
        self?.fullScreenReading() ?? false
    }

    /// The last answer from WindowServer, and when it was asked.
    ///
    /// `cursorMoved` runs for every mouse event anywhere on screen, and the
    /// question behind this is `CGWindowListCopyWindowInfo` — a copy of every
    /// window's description. Asked afresh on each event it was nearly all of
    /// the app's CPU while the pointer moved. A reading younger than the
    /// cursor poll is as good as a new one: the poll would not have noticed
    /// the change any sooner. A space or app switch drops it, so those
    /// still answer at once.
    private var lastFullScreenReading: (at: Date, screen: NSScreen?, value: Bool)?
    static let fullScreenReadingLifetime: TimeInterval = 0.25

    private func fullScreenReading() -> Bool {
        let screen = currentScreen()
        let now = Date()
        if let last = lastFullScreenReading,
           last.screen === screen,
           now.timeIntervalSince(last.at) < Self.fullScreenReadingLifetime {
            return last.value
        }
        let value = FullScreenDetector.isFullScreenAppFrontmost(on: screen)
        lastFullScreenReading = (now, screen, value)
        return value
    }

    /// Whether a frontmost full-screen app may fold the notch at all. A
    /// setting rather than a rule: on a screen kept full-screen all day the
    /// fold reads as the notch refusing to stay put, not as it tidying up.
    var foldsForFullScreen = true

    /// When a full-screen app is active on the current space, auto-folds the notch.
    /// When returning to a desktop space with `isAlwaysOn`, restores the unfolded state.
    func handleActiveSpaceOrAppChange() {
        if foldsForFullScreen && isFullScreenActive() && !model.isPinned {
            if let panel {
                let local = localCursor(in: panel.frame)
                let overTooltip = model.hoveredIndex
                    .flatMap(tooltipRect(index:))
                    .map { model.isExpanded && $0.contains(local) } ?? false
                if liveRect.contains(local) || overTooltip {
                    return
                }
            }
            foldForFullScreen()
        } else if (model.isAlwaysOn || model.isPinned) && !model.isExpanded {
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = true
            }
            updateInteractiveRects()
        }
    }

    /// Immediately folds the notch and clears pending hover timers when a full-screen app takes focus.
    func foldForFullScreen() {
        if let peekUntil, peekUntil > Date() { return }
        foldWork?.cancel()
        foldWork = nil
        guard model.isExpanded else { return }
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = false
            model.hoveredIndex = nil
        }
        setPointing(false)
        updateInteractiveRects()
    }

    /// Re-evaluated on the spot rather than on the next cursor poll, so the
    /// notch answers the setting in the same beat: switched off under a
    /// frontmost full-screen app, an always-on notch comes straight back.
    func apply(foldsForFullScreen: Bool) {
        self.foldsForFullScreen = foldsForFullScreen
        if !foldsForFullScreen {
            // A fold already in flight captured ignoreAlwaysOn and would land
            // once more against an always-on notch, even as the setting that
            // caused it is being switched off.
            foldWork?.cancel()
            foldWork = nil
        }
        handleActiveSpaceOrAppChange()
    }

    func show() {
        relocate()
        startWatchingCursor()
        startWatchingFullScreen()
        startClock()

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.activeSpaceDidChangeNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreenMayHaveChanged() }
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.fullScreenMayHaveChanged() }
        }
        .store(in: &cancellables)

        model.$hoveredIndex
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        model.$activeResetAlert
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        model.$updatePrompt
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        // A model can gain speed rows without changing the cell count. Read
        // after Published's willSet so sizing sees the new card contents too.
        model.$snapshots
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relocate() }
            .store(in: &cancellables)

        // Projection lines come and go with the pace switch and the clock, not
        // with a new reading. Counted after the hop, once both values have landed.
        model.$showsUsagePace.combineLatest(model.$now)
            .receive(on: RunLoop.main)
            .map { [model] _ in model.projectionRows }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.relocate() }
            .store(in: &cancellables)

        // No `receive(on:)`: the appearance has to be on the window before the
        // next draw, or the frame's hexes and the glass would be resolved
        // against the appearance the panel is about to stop having.
        model.$surfaceStyle
            .removeDuplicates()
            .sink { [weak self] style in
                MainActor.assumeIsolated { self?.applyPanelAppearance(style) }
            }
            .store(in: &cancellables)

        // Reduce transparency resolves the glass style to the solid one, so
        // turning it on or off in System Settings changes what the panel's
        // appearance has to be. Nothing else republishes that: the style the
        // model holds has not changed.
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyPanelAppearance(self.model.surfaceStyle)
            }
        }
        .store(in: &cancellables)
    }

    private func applyPanelAppearance(_ style: NotchSurfaceStyle) {
        panel?.appearance = style.panelAppearance(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    func stop() {
        setPointing(false)
        peekUntil = nil
        peekWork?.cancel()
        foldWork?.cancel()
        cursorTimer?.invalidate()
        cursorTimer = nil
        fullScreenTimer?.invalidate()
        fullScreenTimer = nil
        fullScreenFollowUp?.cancel()
        fullScreenFollowUp = nil
        clockTimer?.invalidate()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        cancellables.removeAll()
    }

    // MARK: - Placement

    /// The screen this notch lives on: its assigned display while that display
    /// is still connected, the menu-bar screen otherwise — so unplugging the
    /// display never strands the panel on a screen that no longer exists.
    /// Assigned first — the fleet has already picked this display for this
    /// controller, which is the whole point of there being more than one
    /// controller. `displayPreference` only comes into play once nothing has
    /// been assigned, which is the single-controller case `.mainDisplay`
    /// scope leaves it in.
    func currentScreen() -> NSScreen? {
        if let assigned = assignedScreen,
           NSScreen.screens.contains(where: { $0 === assigned }) {
            return assigned
        }
        return NotchGeometry.preferredScreen(from: NSScreen.screens, preference: displayPreference)
    }

    func relocate(cellCount: Int? = nil) {
        guard let screen = currentScreen() else { return }
        model.adopt(screen: screen)
        let size = model.panelSize(cellCount: cellCount ?? model.snapshots.count)
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: model.edge,
            alongOffset: model.alongOffset, slack: model.slack,
            // In the hand, right up to the screen's end: the room kept for the
            // handles past the notch's ends held it short of each corner, and
            // the passage round the corner — drawn from the corner — started a
            // step away from where the notch had stopped.
            trailingExtent: isOptionDragging ? 0 : model.trailingExtent,
            leadingExtent: isOptionDragging ? 0 : model.leadingExtent,
            heldBar: model.holdsOffTheCutout ? model.plainBarLength : nil
        )

        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            panel.appearance = model.surfaceStyle.panelAppearance(
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            )
            let hosting = NotchHostingView(rootView: NotchRootView(model: model))
            panel.contextMenuProvider = { [weak self] in self?.contextMenu() }
            panel.onClick = { [weak self] point in self?.handleClick(at: point) }
            panel.onDragStart = { [weak self] in self?.beginOptionDrag() }
            // The grip carries the notch without ⌥, the same way.
            panel.startsDrag = { [weak self] point in
                guard let self, let panel = self.panel else { return false }
                let local = CGPoint(x: point.x, y: panel.frame.height - point.y)
                return self.gripRevealed && self.isOverGrip(local)
            }
            panel.onDrag = { [weak self] dx, dy in self?.dragged(dx: dx, dy: dy) }
            panel.onDragEnd = { [weak self] in
                // Where it lands is saved by the landing — see `putDown` — not
                // here: a drag let go near the hole is not where it stays.
                self?.endOptionDrag()
            }

            // The hosting view goes *inside* a plain container rather than
            // being the content view itself.
            //
            // As the content view, SwiftUI gets a say in the window's frame: it
            // reports the content's ideal size, and this view's root is a
            // `GeometryReader`, whose ideal size is 10x10. On the side edges
            // that never surfaced. Turned horizontal, AppKit started walking
            // the window down toward it — 522pt of height to 266, to 10, to
            // zero — until nothing was drawn at all and the constraint pass
            // gave up and threw, taking the app with it.
            //
            // A container removes the channel instead of arguing with it. The
            // panel's size comes from `NotchGeometry` and from nowhere else,
            // which is what every hit region in this file already assumes.
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            if !Runtime.isUnderTest { panel.orderFrontRegardless() }
            self.panel = panel
            self.hostingView = hosting
        }
        // Use the actual panel origin: near a corner its transparent padding
        // can extend offscreen, while the tooltip itself must stay visible.
        if let panel {
            let visible = panel.frame.intersection(screen.frame)
            let range: ClosedRange<CGFloat> = model.edge.isVertical
                ? (panel.frame.maxY - visible.maxY)...(panel.frame.maxY - visible.minY)
                : (visible.minX - panel.frame.minX)...(visible.maxX - panel.frame.minX)
            if model.visibleAlongRange != range { model.visibleAlongRange = range }
        }

        // The frame AppKit actually gave us, which is what the flush right-hand
        // edge depends on.
        if let panel {
            Log.usage.debug("panel \(NSStringFromRect(panel.frame), privacy: .public) on screen \(NSStringFromRect(screen.frame), privacy: .public)")
        }
        updateInteractiveRects()
    }

    /// Feeds a raw pointer delta from an ⌥-drag into `model.alongOffset` and
    /// re-places the panel at once, so the pill tracks the cursor rather than
    /// catching up once the button lifts.
    ///
    /// Both deltas are used as `NSEvent` reports them, unflipped: `deltaY`
    /// positive is the pointer moving *down* the screen, `deltaX` positive is
    /// it moving *right*. `NotchGeometry` is written to match — it subtracts
    /// the offset from a vertical edge's y (which AppKit grows *up*, so
    /// subtracting more moves the pill down) and adds it to a horizontal
    /// edge's x — so no sign flip belongs here; adding one would make the
    /// pill run away from the cursor instead of following it.
    private func dragged(dx: CGFloat, dy: CGFloat) {
        // Again on every step: whatever is under the pointer would otherwise
        // put its own cursor back.
        NSCursor.closedHand.set()
        guard let screen = currentScreen() else { return }
        travel(on: screen)
    }

    /// Where the pointer has taken a held notch, before the hole's pull.
    private var heldPointer: CGFloat = 0

    private func beginOptionDrag() {
        guard !isOptionDragging, !settling else { return }
        isOptionDragging = true
        dragStartEdge = model.edge
        defer {
            if let screen = currentScreen() {
                travelSizes = Dictionary(uniqueKeysWithValues:
                    NotchEdge.allCases.map { ($0, model.travelSize(on: $0)) })
                grip(on: screen)
                // Up now, empty, so the first corner has nothing to wait for.
                let overlay = CornerPassageOverlay(screen: screen)
                overlay.prepare()
                passage = overlay
                // Drawn from the press, not the first movement: taking hold of
                // it is itself a movement, and the drawing taking over part
                // way through cut it short.
                travel(on: screen)
            }
        }
        clearHoverWork?.cancel()
        clearHoverWork = nil
        foldWork?.cancel()
        foldWork = nil
        model.hoveredIndex = nil
        pickUp()
        // Taken by its dots, with the settings button out beside them — or
        // by ⌥-drag, with nothing out.
        let fromHover = model.isExpanded && (model.isHoveringSettings || model.isHoveringMove)
        model.isHoveringSettings = false
        model.isHoveringMove = false
        // In the hand: the hand closes on it, and its settings end turns into
        // the dots that hold it — see `CarriedHandle`.
        setCursor(.closedHand)
        model.carry = Carry(at: Date(), fromHover: fromHover)
        updateInteractiveRects()
    }

    private func endOptionDrag() {
        guard isOptionDragging, !settling else { return }
        model.carry?.releasedAt = Date()
        // **Let go round a corner, it flows off it.** On along the border, on
        // the same glide it followed the hand with, to where the whole of it
        // is on whichever edge more of it was already on — straightening as
        // it goes — and lands there. Pulled onto the edge in one frame, it
        // snapped from the bend to its resting shape: the stiffness.
        //
        // **And let go anywhere, it comes to rest rather than stopping dead.**
        // It had been a step behind the hand, gliding, and letting go put it
        // under the hand in one frame — then, freed of the drag, pulled it
        // back in from the corner in another, clear of the room its handles
        // need. Both are now the end of the same glide: on to where it will
        // stay, and it lands on arriving.
        guard let screen = currentScreen() else { finishDrag(); return }
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        var target = travelTarget ?? travelShown
        if let round = passing {
            let (first, second) = BorderTrack.edges(of: round.corner)
            let onto = round.before >= round.after ? first : second
            let half = travelSize(onto).length / 2 + 1
            let corner = track.position(of: round.corner)
            target = track.wrapped(onto == first ? corner - half : corner + half)
        }
        guard let place = target else { finishDrag(); return }
        travelTarget = resting(place, on: track)
        settling = true
        startFollowing()
    }

    /// Where the notch comes to rest for a middle at `place`: on its edge, and
    /// within the room kept either end for its handles. Beside the Mac's notch
    /// the landing decides instead — see `putDown`.
    private func resting(_ place: CGFloat, on track: BorderTrack) -> CGFloat {
        let (edge, along) = track.place(at: place)
        if let screen = currentScreen(), besideTheHole(place, on: track, screen: screen) { return place }
        let half = travelSize(edge).length / 2
        let size = edge.isVertical ? track.height : track.width
        // The room the handles keep at each end once it is down — worked out
        // for a notch clear of the hole, which is where this one lands, not
        // from how the notch is now. Short of it, it came to rest in a corner
        // and was then pushed out of it by that much in a frame: a landing
        // and then a jump. On the top edge of a display with a notch it was
        // not kept at all.
        let room = model.freeTrailingExtent
        // The notch's leading end is at the smaller `along` on every edge;
        // the settings button and its grip are past its trailing one.
        let low = half, high = size - half - room
        let held = low <= high ? min(max(along, low), high) : size / 2
        let point = edge.isVertical ? CGPoint(x: 0, y: held) : CGPoint(x: held, y: 0)
        return track.position(on: edge, of: point)
    }

    /// Let go round a corner and flowing off it — see `endOptionDrag`.
    private var settling = false

    private func finishDrag() {
        settling = false
        // Landed: the dots fade and the arc comes back, on the notch itself
        // from here — the same frame the drawing would have shown.
        let landed = Date()
        model.carry?.landedAt = landed
        DispatchQueue.main.asyncAfter(deadline: .now() + Carry.settles) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.carry?.landedAt == landed else { return }
                self.model.carry = nil
            }
        }
        // Taken by its dots: set down with them out beside the settings
        // button, as it was taken — and held so while the pointer rests where
        // it let go, whether or not the landing left it over them.
        if model.carry?.fromHover == true {
            restingOnGrip = NSEvent.mouseLocation
            model.isHoveringMove = true
        }
        let landing = stopTravelling()
        isOptionDragging = false
        // The notch itself again, exactly where the drawing of it came to rest.
        if let place = landing, let screen = currentScreen() {
            let frame = screen.frame
            endOverlay(at: place, on: BorderTrack(width: frame.width, height: frame.height), frame: frame)
        }
        // Gone round onto another edge: that is the edge now, and where along
        // it is saved by the landing below, against it.
        if let start = dragStartEdge, model.edge != start {
            onMoveToEdge?(model.edge, model.holdsOffTheCutout ? nil : model.alongOffset)
        }
        dragStartEdge = nil
        passage?.hide()
        passage = nil
        // Set down: the hand lets go.
        setCursor(nil)
        // Back inside the room kept for the handles, now it is not in the hand.
        if !model.holdsOffTheCutout { relocate() }
        putDown()
        cursorMoved()
    }

    // MARK: - Round the screen's edges

    /// The edge an ⌥-drag started on, so letting go knows whether it went
    /// round onto another.
    private var dragStartEdge: NotchEdge?

    /// **How much nearer another edge the pointer has to be before the notch
    /// goes round onto it** — enough that a pointer near a corner does not
    /// send it back and forth between the two.
    static let edgeSwitchMargin: CGFloat = 40

    /// **The ⌥-dragged notch keeps to the screen's frame, and goes round it.**
    ///
    /// Where it is is a place on the screen's border — see `BorderTrack` —
    /// following the pointer's place on it, held at the distance from it that
    /// it was picked up at. Along an edge it is the notch, sliding: on the top
    /// edge of a display with a notch, in the hand beside the hole with the
    /// hole's pull on it. Reaching round a corner, it is drawn wrapping the
    /// corner instead, on a surface over the whole screen, with the notch
    /// itself faded out above it; clear of the corner on the next edge, the
    /// notch is back, there. Going round one frame at a time the wrap is one
    /// band sliding round the bend — see `CornerPassageView`.
    private func travel(on screen: NSScreen) {
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        let local = CGPoint(x: NSEvent.mouseLocation.x - frame.minX,
                            y: frame.maxY - NSEvent.mouseLocation.y)
        // The pointer's place on the border — from the edge it is nearest, or
        // near a corner from both edges at once — and when the reading changes,
        // the grip taken up so the notch does not jump.
        let appKit = NSEvent.mouseLocation
        let edge = Self.stickyEdge(current: pointerEdge, pointer: appKit, frame: frame)
        let reading = Self.reading(of: local, on: track, nearest: edge)
        if reading != pointerReading {
            var step = Self.place(of: local, on: track, by: pointerReading)
                - Self.place(of: local, on: track, by: reading)
            if step > track.perimeter / 2 { step -= track.perimeter }
            if step < -track.perimeter / 2 { step += track.perimeter }
            grip += step
            pointerReading = reading
        }
        pointerEdge = edge
        // Where the hand has it. The notch follows on the display's own beat —
        // see `follow`.
        travelTarget = track.wrapped(Self.place(of: local, on: track, by: pointerReading) + grip)
        startFollowing()
    }

    /// **How the pointer's place on the border is read.** Along the edge it is
    /// nearest; or, within `cornerReach` of both edges at a corner, from both
    /// at once — how far it is from the edge before the corner, less how far
    /// from the edge after, so moving along either one, or away from either,
    /// moves it round. Read from one edge there, the pointer stopped by the
    /// screen's corner moved nothing until it was well down the next edge, and
    /// the notch sat pinned in the corner the while.
    enum Reading: Equatable {
        case edge(NotchEdge)
        case corner(BorderTrack.Corner)
    }

    static let cornerReach: CGFloat = 160

    static func reading(of point: CGPoint, on track: BorderTrack, nearest: NotchEdge) -> Reading {
        for corner in BorderTrack.Corner.allCases {
            let (before, after) = BorderTrack.edges(of: corner)
            if distance(to: before, of: point, on: track) < cornerReach,
               distance(to: after, of: point, on: track) < cornerReach {
                return .corner(corner)
            }
        }
        return .edge(nearest)
    }

    static func place(of point: CGPoint, on track: BorderTrack, by reading: Reading) -> CGFloat {
        switch reading {
        case .edge(let edge):
            return track.position(on: edge, of: point)
        case .corner(let corner):
            let (before, after) = BorderTrack.edges(of: corner)
            return track.wrapped(track.position(of: corner)
                                 + distance(to: before, of: point, on: track)
                                 - distance(to: after, of: point, on: track))
        }
    }

    /// How far a point in the screen's top-left-origin space is from `edge`.
    static func distance(to edge: NotchEdge, of point: CGPoint, on track: BorderTrack) -> CGFloat {
        switch edge {
        case .top:    return max(0, point.y)
        case .bottom: return max(0, track.height - point.y)
        case .left:   return max(0, point.x)
        case .right:  return max(0, track.width - point.x)
        }
    }

    /// How the pointer's place is being read right now.
    private var pointerReading: Reading = .edge(.top)

    /// **Draws the notch with its middle at `place` on the border.**
    ///
    /// In the hand it is drawn on the one surface over the whole screen, along
    /// the edges and round the corners alike — see `CornerPassageView` — and
    /// the notch's own window waits, out of sight, where it will land. Handing
    /// it back and forth at every corner was a jump each way, the two never
    /// quite the same, and moving a window every frame along the edges was a
    /// stutter the screen does not keep time with. Only beside the Mac's notch
    /// is it the notch itself, for the hole's pull and the join.
    private func show(at place: CGFloat, on screen: NSScreen) {
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        if besideTheHole(place, on: track, screen: screen) {
            endOverlay(at: place, on: track, frame: frame)
            put(at: place, on: track, frame: frame)
            return
        }
        let speed = abs(travelVelocity)
        let stretch = Self.maxStretch * min(1, speed / Self.stretchSpeed)
        showOverlay(at: place, on: track, screen: screen,
                    stretch: stretch, heading: travelVelocity >= 0 ? 1 : -1)
    }

    /// Whether a middle at `place` has the notch within the Mac's notch's reach.
    private func besideTheHole(_ place: CGFloat, on track: BorderTrack, screen: NSScreen) -> Bool {
        guard let cutout = screen.hardwareNotch else { return false }
        let (edge, along) = track.place(at: place)
        guard edge == .top else { return false }
        let bar = model.plainBarLength
        let free = along - track.width / 2 - cutout.width / 2 + NotchGeometry.cutoutOverlap - bar / 2
        return NotchGeometry.cutoutFreelyNear(alongOffset: free, width: cutout.width, bar: bar)
    }

    // MARK: - Following the hand

    /// Where the hand has the notch's middle on the border, where it is
    /// drawn, and how fast that is moving along it.
    private var travelTarget: CGFloat?
    private var travelShown: CGFloat?
    private var travelVelocity: CGFloat = 0
    private var follower: CADisplayLink?
    private var ticker: DisplayTick?
    private var lastTick: CFTimeInterval?

    /// **The notch follows the hand on a spring**, not an ease: it carries its
    /// speed, catches up, and comes to rest with the smallest give past the
    /// hand and back, the way something poured does — where an ease just
    /// slowed to a stop. How quick, and how much give: a hand's pull is
    /// brisk and all but dead; flowing off a corner on its own it is gentler,
    /// with a little more.
    static let followResponse: CGFloat = 0.2
    static let followDamping: CGFloat = 0.84
    static let settleResponse: CGFloat = 0.3
    static let settleDamping: CGFloat = 0.74

    /// **How much it stretches with speed**: dragged fast it draws out along
    /// the way it is going and thins, its back end trailing, and it takes its
    /// own shape again as it slows. As much as this share of its length, at
    /// `stretchSpeed` points a second.
    static let maxStretch: CGFloat = 0.14
    static let stretchSpeed: CGFloat = 2600

    /// One frame of the spring: how far it moves toward a target `gap` away,
    /// and its speed after. Two half steps, which keeps a stiff spring steady
    /// at a slow frame.
    static func spring(gap: CGFloat, velocity: CGFloat, elapsed: CGFloat,
                       response: CGFloat, damping: CGFloat) -> (moved: CGFloat, velocity: CGFloat) {
        let omega = 2 * .pi / response
        var moved: CGFloat = 0, velocity = velocity
        for _ in 0..<2 {
            let dt = elapsed / 2
            let acceleration = omega * omega * (gap - moved) - 2 * damping * omega * velocity
            velocity += acceleration * dt
            moved += velocity * dt
        }
        return (moved, velocity)
    }

    private func startFollowing() {
        guard follower == nil, let screen = currentScreen() else { return }
        // On the display's own beat, once a frame — a timer of its own ran in
        // and out of step with the screen and moved the notch twice in one
        // frame and not at all in the next.
        let tick = DisplayTick { [weak self] link in
            MainActor.assumeIsolated { self?.follow(link) }
        }
        let link = screen.displayLink(target: tick, selector: #selector(DisplayTick.tick(_:)))
        // Common modes: the drag holds the run loop in event tracking.
        link.add(to: .main, forMode: .common)
        follower = link
        ticker = tick
        lastTick = nil
    }

    private func stopFollowing() {
        follower?.invalidate()
        follower = nil
        ticker = nil
        lastTick = nil
    }

    /// One frame: the spring's pull toward where the hand has it, and the
    /// notch drawn where that leaves it — stretched by how fast it is going.
    private func follow(_ link: CADisplayLink) {
        guard let target = travelTarget, let screen = currentScreen() else { return }
        let track = BorderTrack(width: screen.frame.width, height: screen.frame.height)
        let elapsed = CGFloat(min(max(link.timestamp - (lastTick ?? link.timestamp - link.duration), 0), 1.0 / 30))
        lastTick = link.timestamp
        guard let shown = travelShown else {
            travelShown = target
            travelVelocity = 0
            show(at: target, on: screen)
            return
        }
        var gap = target - shown
        if gap > track.perimeter / 2 { gap -= track.perimeter }
        if gap < -track.perimeter / 2 { gap += track.perimeter }
        if abs(gap) < (settling ? 0.3 : 0.05), abs(travelVelocity) < (settling ? 6 : 1) {
            travelVelocity = 0
            // Flowed off the corner and come to rest: now it lands.
            if settling { finishDrag() }
            return
        }
        let (position, velocity) = Self.spring(
            gap: gap, velocity: travelVelocity, elapsed: elapsed,
            response: settling ? Self.settleResponse : Self.followResponse,
            damping: settling ? Self.settleDamping : Self.followDamping)
        travelVelocity = velocity
        let next = track.wrapped(shown + position)
        travelShown = next
        show(at: next, on: screen)
    }

    /// Done following: at where it was going, and that place.
    @discardableResult
    private func stopTravelling() -> CGFloat? {
        stopFollowing()
        let place = travelTarget ?? travelShown
        if let place, let screen = currentScreen() {
            travelShown = place
            show(at: place, on: screen)
        }
        travelTarget = nil
        travelShown = nil
        travelVelocity = 0
        return place
    }

    /// The notch on its edge with its middle at `place` on the border.
    private func put(at place: CGFloat, on track: BorderTrack, frame: CGRect) {
        let (edge, along) = track.place(at: place)
        if edge != model.edge {
            model.hoveredIndex = nil
            model.holdsOffTheCutout = false
            model.edge = edge
        }
        let point = edge.isVertical
            ? CGPoint(x: frame.minX, y: frame.maxY - along)
            : CGPoint(x: frame.minX + along, y: frame.maxY)
        let offset = Self.offset(along: edge, at: point, on: frame)
        if let cutout = heldCutout {
            // The hand's own measure beside the hole: from its right wall to
            // the bar's leading tip, so the bar's middle is at `place`; then
            // the hole's pull on it.
            let bar = model.plainBarLength
            heldPointer = offset - cutout.width / 2 + NotchGeometry.cutoutOverlap - bar / 2
            model.holdsOffTheCutout = true
            model.alongOffset = NotchGeometry.magnetised(heldPointer, width: cutout.width, bar: bar)
        } else {
            model.alongOffset = offset
        }
        relocate()
        updateInteractiveRects()
    }

    /// Takes hold: how far along the border the notch's middle is from the
    /// pointer's place, so it keeps that distance as it travels.
    private func grip(on screen: NSScreen) {
        let frame = screen.frame
        let track = BorderTrack(width: frame.width, height: frame.height)
        pointerEdge = model.edge
        let local = CGPoint(x: NSEvent.mouseLocation.x - frame.minX,
                            y: frame.maxY - NSEvent.mouseLocation.y)
        pointerReading = Self.reading(of: local, on: track, nearest: model.edge)
        guard let panel else { grip = 0; return }
        let wing = model.cellWing
        let middle = model.edge.isVertical
            ? CGPoint(x: 0, y: frame.maxY - panel.frame.maxY + wing.lead + wing.length / 2)
            : CGPoint(x: panel.frame.minX - frame.minX + wing.lead + wing.length / 2, y: 0)
        var distance = track.position(on: model.edge, of: middle)
            - Self.place(of: local, on: track, by: pointerReading)
        if distance > track.perimeter / 2 { distance -= track.perimeter }
        if distance < -track.perimeter / 2 { distance += track.perimeter }
        grip = distance
    }

    /// How far along the border the notch's middle is from the pointer's place.
    private var grip: CGFloat = 0
    /// The edge the pointer's place on the border is read from.
    private var pointerEdge: NotchEdge = .top

    // MARK: - Drawn on the screen while in the hand

    private var passage: CornerPassageOverlay?
    /// Whether the drawing is standing in for the notch right now.
    private var overlaid = false
    /// Where the notch was going round when the drag last moved, for a let-go
    /// mid-corner to flow off from.
    private var passing: (corner: BorderTrack.Corner, before: CGFloat, after: CGFloat)?

    /// The notch in the hand on each edge — see `NotchViewModel.travelSize` —
    /// worked out when the drag began.
    private var travelSizes: [NotchEdge: NotchViewModel.TravelSize] = [:]

    private func travelSize(_ edge: NotchEdge) -> NotchViewModel.TravelSize {
        travelSizes[edge] ?? model.travelSize(on: edge)
    }

    /// **The notch at `place` on the border**: the corner it is going round, if
    /// any, how far round, and how long it is there — turning from the one
    /// edge's length to the other's as it goes round, so there is no size it
    /// arrives at in a step.
    private func shape(at place: CGFloat, on track: BorderTrack, stretch: CGFloat = 0)
    -> (round: (corner: BorderTrack.Corner, before: CGFloat, after: CGFloat)?, length: CGFloat, turned: CGFloat) {
        let drawn = 1 + stretch
        var length = travelSize(track.place(at: place).edge).length * drawn
        guard var round = track.corner(for: place, length: length) else { return (nil, length, 0) }
        let (first, second) = BorderTrack.edges(of: round.corner)
        var turned: CGFloat = 0
        // Twice: how far round decides the length, and the length how far round.
        for _ in 0..<2 {
            let t = min(max(round.after / max(length, 1), 0), 1)
            turned = t * t * (3 - 2 * t)
            length = (travelSize(first).length
                      + (travelSize(second).length - travelSize(first).length) * turned) * drawn
            guard let again = track.corner(for: place, length: length) else { return (nil, length, turned) }
            round = again
        }
        return (round, length, turned)
    }

    private func showOverlay(at hand: CGFloat, on track: BorderTrack, screen: NSScreen,
                             stretch: CGFloat = 0, heading: CGFloat = 1) {
        let overlay = passage ?? {
            let made = CornerPassageOverlay(screen: screen)
            passage = made
            return made
        }()
        if !overlaid { passageEdge = model.edge }
        let bleed = NotchRootView.bezelBleed
        let scale = model.sizeScale
        // Stretched, it draws out behind: its front stays with the hand and
        // its middle falls back by half what it gained.
        let resting = travelSize(track.place(at: hand).edge).length
        let back = heading * resting * stretch / 2
        let place = track.wrapped(hand - back)
        let (round, length, turned) = shape(at: place, on: track, stretch: stretch)
        let thin = 1 - stretch * 0.35
        let edges = round.map { BorderTrack.edges(of: $0.corner) }
        let from = travelSize(edges?.before ?? track.place(at: place).edge)
        let to = travelSize(edges?.after ?? track.place(at: place).edge)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * turned }
        overlay.show(CornerPassageView(
            track: track, corner: round?.corner ?? .topLeft,
            before: round?.before ?? length, after: round?.after ?? 0,
            depth: bleed + (from.depth - bleed) * thin,
            depthAfter: bleed + (to.depth - bleed) * thin, bleed: bleed,
            cornerRadius: model.drawnCornerRadius * scale, flare: model.flare * scale,
            place: place, rings: passageRings(from: from, to: to, turned: turned, carriedBy: back),
            ringInset: mix(from.ringAcross, to.ringAcross) - bleed,
            ringScale: scale,
            straight: round == nil ? track.place(at: place).edge : nil,
            arcs: passageArcs(at: place, length: length, on: track),
            carry: model.carry))
        passing = round.map { ($0.corner, $0.before, $0.after) }
        guard !overlaid else { return }
        overlaid = true
        // Handed over, not faded: the drawing is exactly where the notch is,
        // so the notch simply goes — a turn later, once the drawing is on
        // screen under it, so there is no frame with neither.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.overlaid else { return }
                self.panel?.alphaValue = 0
            }
        }
    }

    /// The notch itself again, put where the drawing had it first.
    private func endOverlay(at place: CGFloat, on track: BorderTrack, frame: CGRect) {
        guard overlaid else { return }
        overlaid = false
        passing = nil
        put(at: place, on: track, frame: frame)
        panel?.alphaValue = 1
        let overlay = passage
        // Emptied a turn later, for the same reason the notch went a turn late.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard self?.overlaid == false else { return }
                overlay?.clear()
            }
        }
    }

    /// The edge the notch was on when the drawing took over, whose layout its
    /// rings keep all the way round.
    private var passageEdge: NotchEdge = .top

    /// **The handles' resting arcs, at the two ends of the notch** — the
    /// settings arc at the end that was the trailing one when the drawing took
    /// over, the move arc (when it is shown) at the other — each in the pocket
    /// of the flare at the end it hangs off, facing back along the notch, on
    /// whatever edge that end is on. Left out, they went out at every pick-up
    /// and came back at every landing.
    private func passageArcs(at place: CGFloat, length: CGFloat, on track: BorderTrack) -> [PassageArc] {
        let scale = model.sizeScale
        let sign: CGFloat = passageEdge == .top || passageEdge == .right ? 1 : -1
        let flare = model.flare * scale
        var arcs: [PassageArc] = []
        // The settings arc alone: the grip that moves the notch comes out with
        // the settings button, and has no arc of its own.
        for (id, towardEnd) in [(0, sign)] {
            let end = track.wrapped(place + towardEnd * length / 2)
            let (edge, along) = track.place(at: end)
            // Which way along this edge the rest of the notch is: back toward
            // the middle, the border's own direction there one way or other.
            let runs: CGFloat = edge == .top || edge == .right ? 1 : -1
            let bodyToward = runs * -towardEnd
            let trim = bodyToward > 0
                ? MoveHandle.restingTrim(for: edge, convex: false)
                : SettingsOrb.restingTrim(for: edge, convex: false)
            let w = track.width, h = track.height
            let centre: CGPoint
            switch edge {
            case .top:    centre = CGPoint(x: along, y: flare)
            case .bottom: centre = CGPoint(x: along, y: h - flare)
            case .left:   centre = CGPoint(x: flare, y: along)
            case .right:  centre = CGPoint(x: w - flare, y: along)
            }
            let away = edge.isVertical ? CGPoint(x: 0, y: -bodyToward) : CGPoint(x: -bodyToward, y: 0)
            arcs.append(PassageArc(id: id, centre: centre, edge: edge, trim: trim,
                                   radius: (model.flare - NotchLayout.orbClearance) * scale,
                                   gap: NotchLayout.orbClearance * scale,
                                   stroke: NotchLayout.orbStroke * scale,
                                   away: away, reach: model.gripReach))
        }
        return arcs
    }

    /// The rings, as the notch carries them — the very cells, readings and
    /// all, so the drawing and the notch are the same to the point: each one's
    /// distance from the notch's middle along the border, turning from where
    /// it is on the one edge to where it is on the next. Kept in the order the
    /// notch had them when the drawing took over, so none of them ever swaps
    /// places mid-drag.
    private func passageRings(from: NotchViewModel.TravelSize, to: NotchViewModel.TravelSize,
                              turned: CGFloat, carriedBy back: CGFloat = 0) -> [PassageRing] {
        // The border runs the same way as the notch's own stack on the top and
        // right edges, and the other way on the bottom and left.
        let sign: CGFloat = passageEdge == .top || passageEdge == .right ? 1 : -1
        return model.snapshots.enumerated().map { index, snapshot in
            // The cell's middle, which is where it is placed: its ring's, moved
            // down the stack past a reading under it on a side edge.
            let a = (from.ringCenters[safe: index] ?? 0) + from.cellShift - from.length / 2
            let b = (to.ringCenters[safe: index] ?? 0) + to.cellShift - to.length / 2
            return PassageRing(
                id: snapshot.id,
                cell: ProviderCell(snapshot: snapshot,
                                   activity: model.activity(for: snapshot),
                                   isRefreshing: model.isRefreshing(snapshot),
                                   weeklyRing: model.weeklyRing,
                                   showsWeeklyReading: model.weeklyReading,
                                   showsReading: model.showsCellReading),
                // The rings are solid: stretching the notch does not move
                // them off the hand.
                offset: sign * (a + (b - a) * turned) + back)
        }
    }

    /// The edge the notch belongs on for a pointer at `pointer`: the one it is
    /// on, unless another is nearer by more than `edgeSwitchMargin`.
    static func stickyEdge(current: NotchEdge, pointer: CGPoint, frame: CGRect) -> NotchEdge {
        let nearest = NotchEdge.allCases.min {
            distance(from: $0, of: pointer, on: frame) < distance(from: $1, of: pointer, on: frame)
        } ?? current
        let here = distance(from: current, of: pointer, on: frame)
        let there = distance(from: nearest, of: pointer, on: frame)
        return there + edgeSwitchMargin < here ? nearest : current
    }

    /// How far `point` is from `edge` of `frame`, into the screen.
    static func distance(from edge: NotchEdge, of point: CGPoint, on frame: CGRect) -> CGFloat {
        switch edge {
        case .top:    return frame.maxY - point.y
        case .bottom: return point.y - frame.minY
        case .left:   return point.x - frame.minX
        case .right:  return frame.maxX - point.x
        }
    }

    /// The offset along `edge` that centres the notch on `point`, in the
    /// measure `NotchGeometry.panelFrame` places it by: x to the right of the
    /// middle on a horizontal edge, y *down* from the middle on a vertical one.
    static func offset(along edge: NotchEdge, at point: CGPoint, on frame: CGRect) -> CGFloat {
        edge.isVertical ? frame.midY - point.y : point.x - frame.midX
    }

    // MARK: - The notch in the hand

    /// The hole on the screen the notch is on, if it is on the one edge that
    /// has one.
    private var heldCutout: HardwareNotch? {
        guard model.edge == .top else { return nil }
        return currentScreen()?.hardwareNotch
    }

    /// **Picked up, it lets go of the hole.**
    ///
    /// A joined notch is attached and cannot follow the pointer: dragging it
    /// used to move only how deep it was buried, which nothing on screen shows,
    /// so the drag went dead for fifty points and then jumped. In the hand it is
    /// a lone bar measured the plain way — leading tip point for point with the
    /// pointer — and it lets go of the hole on the fold's spring. The window is
    /// the same before and after, which is the only reason that may be eased.
    private func pickUp() {
        guard let cutout = heldCutout, !model.holdsOffTheCutout else { return }
        let free = NotchGeometry.freeOffset(fromStanding: model.alongOffset,
                                            width: cutout.width, bar: model.plainBarLength)
        let wasJoined = model.mergesWithCutout
        heldPointer = free
        let lift = {
            self.model.revealsTheOtherCopy = false
            self.model.holdsOffTheCutout = true
            self.model.alongOffset = free
            self.relocate()
        }
        if wasJoined { withAnimation(NotchMotion.lift, lift) } else { lift() }
    }

    /// **Put down near the hole, it glides onto the nearer wall and joins it.**
    ///
    /// One movement: onto the wall, in past it, and the hole's size taken, with
    /// the other copy drawn out of the far wall at the same time. It does not
    /// move the window, because the window is the same anywhere near the hole;
    /// that is what lets it ease.
    ///
    /// Put down out of reach, it stays exactly where it was put.
    private func putDown() {
        guard let cutout = heldCutout, model.holdsOffTheCutout else {
            onReposition?(model.alongOffset)
            return
        }
        let bar = model.plainBarLength
        guard let target = NotchGeometry.cutoutLanding(alongOffset: model.alongOffset,
                                                       width: cutout.width, bar: bar)
        else {
            // Out of reach: say where it is the way it is kept, and it stays.
            model.holdsOffTheCutout = false
            model.alongOffset = NotchGeometry.standingOffset(fromFree: model.alongOffset,
                                                             width: cutout.width, bar: bar)
            relocate()
            updateInteractiveRects()
            onReposition?(model.alongOffset)
            return
        }

        // **One movement**, wherever it was let go. The bar travels onto the
        // wall and in past it, takes the hole's size, and the other copy comes
        // out of the far wall, all on one spring. It used to stop at the wall
        // and take the hole a beat later — two movements, the first all but
        // settled before the second set off, which read as landing and then
        // landing again. The end at the wall closes up by where it is, not on
        // the clock (see `SideNotchShape.Dip.closes`), so there is nothing
        // left to wait for.
        withAnimation(NotchMotion.unfold) {
            model.revealsTheOtherCopy = false
            model.holdsOffTheCutout = false
            model.alongOffset = target
            relocate()
        }
        updateInteractiveRects()
        onReposition?(model.alongOffset)
    }

    // MARK: - Hit regions

    /// The panel's real size, which AppKit may have rounded up from the one we
    /// asked for — and which the flush edge depends on.
    private var placement: NotchPlacement {
        NotchPlacement(edge: model.edge, panelSize: panel?.frame.size ?? model.panelSize)
    }

    /// The notch itself, in panel coordinates with a top-left origin.
    private var notchRect: CGRect {
        placement.rect(
            along: model.wings.first?.lead ?? model.slack,
            across: 0,
            length: model.drawnAlongExtent,
            depth: model.notchDepth * model.sizeScale
        )
    }

    /// What wakes the folded notch. Larger than the pill it surrounds, and
    /// exactly the hardware notch when it is joined to one — see
    /// `NotchViewModel.wakeLength` for both halves of that.
    private var pillRect: CGRect {
        // Joined, that is both copies and the hole between them: the hardware's
        // own notch is part of the target, which is the whole point of the
        // notch being drawn as part of it.
        let joined = model.mergesWithCutout
        let length = joined ? model.drawnAlongExtent : model.wakeLength
        let lead = joined
            ? (model.wings.first?.lead ?? model.slack)
            : model.restingAlongLead
                + (model.restingLength * model.sizeScale - model.wakeLength) / 2
        return placement.rect(along: lead, across: 0, length: length, depth: model.wakeDepth)
    }

    /// The handle's bounding box, for deciding whether the panel takes events
    /// at all. Whether a point is actually *on* the handle is a finer question
    /// than a box can answer — see `isOverHandle`.
    private var handleRect: CGRect {
        let side = model.orbHotZone
        // The grip only once it is out: an invisible spot beside the settings
        // button that still takes the mouse would be worse than none.
        let grip = gripRevealed ? [model.gripPoint] : []
        let boxes = (model.orbHandlePoints + grip).map { point -> CGRect in
            let centre = placement.point(along: model.handleWing.lead + point.x * model.sizeScale,
                                         across: point.y * model.sizeScale)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        }
        return boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }

    /// Whether the pointer is on the handle itself rather than merely inside
    /// the box that contains it.
    private func isOverHandle(_ local: CGPoint) -> Bool {
        // Back into the notch's own measurements, which is what `isOnOrbHandle`
        // is written in — the orb scales with the notch, so its hit test has to
        // be asked in the same space the shape was drawn in.
        model.isOnOrbHandle(
            along: (placement.along(of: local) - model.handleWing.lead) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    /// Whether the grip is out: it comes with the settings button, and stays
    /// while the pointer is on it.
    private var gripRevealed: Bool {
        model.isExpanded && (model.isHoveringSettings || model.isHoveringMove)
    }

    /// Whether the pointer is on the grip, asked in the same notch-own
    /// measurements `isOverHandle` uses.
    private func isOverGrip(_ local: CGPoint) -> Bool {
        model.isOnGrip(
            along: (placement.along(of: local) - model.handleWing.lead) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    /// The only region that takes the mouse. Everything else in the panel is a
    /// hole — which matters far more folded than open, since the point of
    /// folding away is to stop being in the way.
    private var liveRect: CGRect {
        guard model.isExpanded else { return pillRect }
        // The orb hangs below the shape, so the live region is both together.
        return notchRect.union(handleRect)
    }

    /// The card, its tail, and the gap between the tail and the notch — so
    /// sliding the pointer off the notch and onto the card never leaves it.
    private func tooltipRect(index: Int) -> CGRect? {
        guard model.snapshots.indices.contains(index) else { return nil }
        let snapshot = model.snapshots[index]
        let cardHeight = NotchLayout.cardHeight(
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
            projectionRowCount: snapshot.projectionRowCount(now: model.now, showsUsagePace: model.showsUsagePace),
            hasUsageHistory: snapshot.chartedHistory != nil,
            showsDeepSeekPricing: model.deepSeekPricingEnabled
        )
        // Across the stack the region is the card, its tail, and the gap the
        // pointer has to cross. Along it, the card's own extent.
        let cardAcross = model.edge.isVertical ? NotchLayout.cardWidth : cardHeight
        let cardAlong = model.edge.isVertical ? cardHeight : NotchLayout.cardWidth
        let centre = model.tooltipAlong(index: index, length: cardAlong)
        return placement.rect(
            along: centre - cardAlong / 2,
            // The card's own extent does not scale, and it begins where the
            // drawn notch ends.
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + cardAcross
        )
    }

    private func resetCardRect(event: UsageResetEvent) -> CGRect? {
        let index = model.resetAlertIndex(for: event) ?? 0
        let cardAcross = model.edge.isVertical ? NotchLayout.cardWidth : UsageResetCard.cardHeight
        let cardAlong = model.edge.isVertical ? UsageResetCard.cardHeight : NotchLayout.cardWidth
        let centre = model.tooltipAlong(index: index, length: cardAlong)
        return placement.rect(
            along: centre - cardAlong / 2,
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + cardAcross
        )
    }

    /// Where the update card is, on the notch's middle — see `UpdateCard`.
    private var updateCardRect: CGRect? {
        guard model.isExpanded, model.updatePrompt != nil else { return nil }
        let size = UpdateCard.size(for: model.edge.tooltipDirection)
        let across = model.edge.isVertical ? size.width : size.height
        let along = model.edge.isVertical ? size.height : size.width
        let centre = model.cardAlong(centredOn: model.notchMiddleAlong, length: along)
        return placement.rect(
            along: centre - along / 2,
            across: model.notchDrawnDepth,
            length: along,
            depth: NotchLayout.tailGap + NotchLayout.tailLength + across
        )
    }

    /// **An update offered, or installing**: the notch opens for it and stays
    /// open until it is answered — see `UpdateCard`.
    func apply(updatePrompt: UpdatePrompt?) {
        let arriving = model.updatePrompt == nil && updatePrompt != nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            model.updatePrompt = updatePrompt
        }
        if arriving, visibility != .hidden, panel != nil {
            model.hoveredIndex = nil
            setExpanded(true)
        }
        updateInteractiveRects()
        // Answered: back to whatever the pointer says.
        if updatePrompt == nil { cursorMoved() }
    }

    private func updateInteractiveRects() {
        var rects = [liveRect]
        if let card = updateCardRect { rects.append(card) }
        if model.isExpanded, let event = model.activeResetAlert, let card = resetCardRect(event: event) {
            rects.append(card)
        }
        if model.isExpanded, let index = model.hoveredIndex, let card = tooltipRect(index: index) {
            rects.append(card)
        }
        hostingView?.interactiveRects = rects
        if let panel {
            // Runs for every mouse event on the screen. AppKit does not skip an
            // unchanged value: each assignment re-sends the window's event mask
            // and tags to WindowServer and flushes a layout pass.
            let ignores = !rects.contains { $0.contains(localCursor(in: panel.frame)) }
            if panel.ignoresMouseEvents != ignores {
                panel.ignoresMouseEvents = ignores
            }
        }
    }

    // MARK: - Cursor tracking

    /// A global monitor catches the outside-to-inside crossing while the panel
    /// is still ignoring events; a local one catches the way back out.
    ///
    /// A slow poll backs both of them up, because a cursor that never moves
    /// produces no events at all — so a notch that appears, resizes or is
    /// re-anchored underneath a parked pointer would otherwise sit there with
    /// stale hover state until the user jogged the mouse.
    /// A space or app switch: answered at once, and once more a moment later,
    /// because an app that has just come forward is often still animating
    /// into full screen when the notification arrives.
    private func fullScreenMayHaveChanged() {
        lastFullScreenReading = nil
        handleActiveSpaceOrAppChange()
        fullScreenFollowUp?.cancel()
        let followUp = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.lastFullScreenReading = nil
                self?.handleActiveSpaceOrAppChange()
            }
        }
        fullScreenFollowUp = followUp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: followUp)
    }

    /// Full screen that posts no notification — a video going full screen in
    /// the browser already in front, a game sizing its window to the display —
    /// is only caught by asking, and asking is a WindowServer round trip.
    /// It rode the 0.3s cursor poll, which made it three of those a second
    /// for as long as the app ran. Every two seconds is soon enough for a
    /// fold nobody is waiting on, and switches are answered by the
    /// notifications above without waiting for it. (From #202.)
    private func startWatchingFullScreen() {
        let poll = Timer(timeInterval: Self.fullScreenPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.foldsForFullScreen else { return }
                self.handleActiveSpaceOrAppChange()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        fullScreenTimer = poll
    }

    private func startWatchingCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func localCursor(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    // Not private: tests drive the hover fold through it, the same way they
    // drive the event fold through handleActiveSpaceOrAppChange.
    func cursorMoved() {
        guard let panel, !isOptionDragging else { return }
        let local = localCursor(in: panel.frame)
        let overTooltip = model.hoveredIndex
            .flatMap(tooltipRect(index:))
            .map { model.isExpanded && $0.contains(local) } ?? false
        // The fold setting gates this check as surely as the one in
        // handleActiveSpaceOrAppChange: left ungated, the hover fold out-votes
        // "Always show" under a full-screen app while the other path keeps
        // restoring it — the notch ends up folding on every poll.
        setExpanded(liveRect.contains(local) || overTooltip,
                    ignoreAlwaysOn: foldsForFullScreen && isFullScreenActive())

        var target: Int?
        if model.isExpanded, notchRect.contains(local) {
            target = cellIndex(along: placement.along(of: local))
        } else if model.isExpanded, let current = model.hoveredIndex,
                  let card = tooltipRect(index: current),
                  card.contains(local) {
            target = current
        }

        var overHandle = model.isExpanded && isOverHandle(local)
        // Out already, or coming out with the settings button now.
        let gripOut = gripRevealed || overHandle
        var overMove = model.isExpanded && gripOut && !overHandle && isOverGrip(local)
        // Just set down by its dots: on them until the pointer moves — see
        // `finishDrag`.
        if let rest = restingOnGrip {
            if NSEvent.mouseLocation == rest {
                overHandle = false
                overMove = true
            } else {
                restingOnGrip = nil
            }
        }
        if model.isHoveringSettings != overHandle {
            model.isHoveringSettings = overHandle
        }
        if model.isHoveringMove != overMove {
            model.isHoveringMove = overMove
        }
        // The grip is held, not clicked: an open hand, ready to close on it.
        let pointing = Self.wantsPointingHand(isExpanded: model.isExpanded, cellIndex: target)
            || overHandle
        setCursor(overMove ? .openHand : pointing ? .pointingHand : nil)

        if let target {
            clearHoverWork?.cancel()
            clearHoverWork = nil
            if model.hoveredIndex != target {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    model.hoveredIndex = target
                }
            }
        } else if model.hoveredIndex != nil, clearHoverWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearHoverWork = nil
                    withAnimation(.easeOut(duration: 0.18)) { self.model.hoveredIndex = nil }
                }
            }
            clearHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverGrace, execute: work)
        }

        updateInteractiveRects()
    }

    /// Opens on contact, folds shut after a pause — unless it has been pinned
    /// open, in which case the pointer is not what decides.
    ///
    /// `ignoreAlwaysOn` is only read when it can change the outcome — a fold
    /// about to be scheduled on a notch that "Always show" would otherwise
    /// hold open — because answering it asks WindowServer.
    private func setExpanded(_ wanted: Bool, ignoreAlwaysOn: @autoclosure () -> Bool = false) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            // Back before it folded: the arcs come out again.
            if model.handlesTuckedAway { model.handlesTuckedAway = false }
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            return
        }

        // An update offered holds it open until it is answered.
        if model.updatePrompt != nil { return }
        // A peek holds the notch open for its own duration; only after that
        // does the pointer get a say again.
        if let peekUntil, peekUntil > Date() { return }
        guard model.isExpanded, foldWork == nil, !model.isPinned else { return }
        // Pinned is settled above; what is left to decide is whether "Always
        // show" holds it, and only a frontmost full-screen app overrules that.
        let ignoresAlwaysOn = model.isAlwaysOn && ignoreAlwaysOn()
        guard ignoresAlwaysOn || !model.isAlwaysOn else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stillHoldsOpen = self.model.isPinned || (self.model.isAlwaysOn && !ignoresAlwaysOn)
                guard !stillHoldsOpen else {
                    self.foldWork = nil
                    return
                }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                // Cleared once folded, so letting go of the pending fold does
                // not bring the arcs back out on its way shut.
                self.foldWork = nil
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        // Left from the settings button or its dots: the button turns back
        // into its arc first — see `DiscToArc` — and only then does the arc
        // go home and the notch fold. At once, the arc was on its way in
        // before the button had become it.
        let fromHandle = model.isHoveringSettings || model.isHoveringMove
        let turnBack: TimeInterval = fromHandle ? SettingsOrb.turnsBack : 0
        // The arcs start home, while the notch is still open to go into — it
        // folds once they are in.
        if turnBack > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + turnBack) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.foldWork === work else { return }
                    self.model.handlesTuckedAway = true
                }
            }
        } else {
            model.handlesTuckedAway = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace + turnBack, execute: work)
    }

    /// The rings are buttons, so they should say so.
    static func wantsPointingHand(isExpanded: Bool, cellIndex: Int?) -> Bool {
        isExpanded && cellIndex != nil
    }

    /// Pushed and popped rather than `set`, so leaving restores whatever cursor
    /// the app underneath had chosen. Setting `.arrow` on the way out would
    /// stamp an arrow over someone else's text caret.
    private func setPointing(_ wanted: Bool) {
        setCursor(wanted ? .pointingHand : nil)
    }

    /// The cursor over the notch: a pointing hand on what clicks, an open hand
    /// on the grip, a closed one while the notch is carried — or the system's
    /// own. One pushed at a time, so each change pops the last.
    private func setCursor(_ wanted: NSCursor?) {
        BackgroundCursor.enable()
        guard wanted !== shownCursor else { return }
        if shownCursor != nil { NSCursor.pop() }
        wanted?.push()
        shownCursor = wanted
    }

    /// A click on a ring refetches that provider; a click anywhere else on the
    /// open notch pins it. The ring is the more specific target, so it wins.
    func handleClick(at locationInWindow: CGPoint) {
        guard let panel else {
            setExpanded(true)
            return
        }
        // Use the event position even if the pointer has moved since the click.
        let local = CGPoint(x: locationInWindow.x, y: panel.frame.height - locationInWindow.y)

        // The handle sits inside the notch, so it has to be tested before the
        // cells — otherwise the cell band nearest the foot of the stack swallows
        // it and clicking the gear refetches a provider instead.
        if model.isExpanded, isOverHandle(local) {
            // The same turn the SwiftUI tap gives it, so the gear responds
            // however the click reached it — this path and the tap gesture
            // are two routes to one action.
            model.settingsSpins += 1
            onOpenSettings?()
            return
        }
        // A peek is a question — "this one just finished, do you want it?" —
        // and the click that follows is the answer. It outranks pinning and
        // refetching for as long as the offer stands, and for no longer.
        //
        // Tested before the folded case below, not after: the grace period
        // outlives the peek by a couple of seconds precisely so that a hand
        // that arrived late still lands on the session, and answering it by
        // merely re-opening the notch would waste that click.
        if takePendingFocus() {
            peekWork?.cancel()
            peekWork = nil
            peekUntil = nil
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
            setPointing(false)
            updateInteractiveRects()
            return
        }
        // Clicks on the tooltip card belong to whatever is drawn there — the
        // session rows take their own taps — and must not fall through to the
        // cell refetch or the pin toggle underneath.
        if model.isExpanded, let index = model.hoveredIndex,
           let card = tooltipRect(index: index), card.contains(local) {
            return
        }
        guard model.isExpanded else {
            // Opens it, the same as the pointer arriving would — it must not
            // also pin it. The pill's hot zone is deliberately generous, since
            // it is a small target on a screen edge, so a click aimed at
            // something else nearby can land here without the notch ever
            // having been seen open. Pinning is what a click on a notch that
            // is *already* open does; folding it back in later is exactly
            // the ordinary hover behaviour, which a plain `setExpanded` leaves
            // intact.
            setExpanded(true)
            return
        }
        if notchRect.contains(local),
           let index = cellIndex(along: placement.along(of: local)),
           model.snapshots.indices.contains(index) {
            if let onRefreshProvider {
                let snapshot = model.snapshots[index]
                Task { await model.refresh(snapshot, using: onRefreshProvider) }
            }
        }
        // Anything else on an open notch does nothing. A click here used to
        // pin it, which read as the notch locking itself: the rings are small
        // targets, a click aimed at one lands beside it easily, and `isPinned`
        // has no drawn state — so the notch simply stopped folding and nothing
        // on screen said why or how to undo it. Keep open is on the
        // right-click menu, where it is named and carries a checkmark.
    }

    /// Move the notch to another screen edge.
    ///
    /// It goes out where it was, crosses while there is nothing to see, and
    /// then **opens** where it now is — the same unfold hovering uses, so a
    /// move ends the way reaching for it does rather than with a bar appearing
    /// at full size.
    ///
    /// Changing the placement moves the panel, turns the shape on its side and
    /// relays the whole stack, all in one frame. Done in view that is a jump no
    /// animation can smooth over, and animating a panel across a corner looks
    /// like a bug rather than a choice — hence the crossing rather than a
    /// slide.
    /// A new size choice: set it, then rebuild the panel around it.
    ///
    /// Set-then-relocate rather than a subscription on `model.$sizeScale`,
    /// because `@Published` fires in `willSet` — a sink here would recompute
    /// the panel from the size that is being replaced. `apply(edge:)` is the
    /// same shape for the same reason.

    func apply(alongOffset: CGFloat) {
        guard model.alongOffset != alongOffset else { return }
        model.alongOffset = alongOffset
        relocate()
    }

    /// The size to start at, before there is a panel to relayout.
    ///
    /// A display plugged in later builds its panel at the current size rather
    /// than at medium and resizing a beat afterwards.
    func prime(scale: CGFloat) {
        model.requestedScale = scale
    }

    /// Whether each ring carries its percentage.
    ///
    /// Relaid out, not merely set: beside the hardware the reading is paid for
    /// out of ring size, so turning it on changes the ring, the strip's length
    /// and the width of the window around it. Set without relocating, the
    /// window keeps its old size and the shape — which centres itself in it —
    /// slides away from the settings arc and the tooltip, both placed from
    /// `slack`. Every setting that moves `panelSize` has to come through here.
    func apply(showsNotchReadings: Bool) {
        guard model.showsNotchReadings != showsNotchReadings else { return }
        model.showsNotchReadings = showsNotchReadings
        relocate()
        updateInteractiveRects()
    }

    func apply(scale: CGFloat) {
        // Against the setting, not against `sizeScale`: the hardware's own notch
        // answers that one, so comparing with it would drop every change the
        // user makes while the notch is merged — and the value still governs
        // every other edge it might be moved to.
        guard model.requestedScale != scale else { return }

        // A drag arrives as a stream of tiny deltas; a preset, or a switch
        // between the two controls, arrives as one large one.
        let isDrag = abs(scale - model.requestedScale) < Self.steppedScaleDelta

        // The drawn shape follows every tick — that part is a redraw and it is
        // cheap. Re-laying the *window* out is not: `relocate` recomputes the
        // panel size through `maxCardHeight` and the `sessionCap` search, then
        // asks the compositor to resize a full-height window. Sixty of those a
        // second is what makes a drag feel like it is pulling something heavy.
        model.requestedScale = scale
        if isDrag {
            coalesceRelocate()
        } else {
            pendingRelocate?.cancel()
            pendingRelocate = nil
            relocate()
            updateInteractiveRects()
        }
    }

    /// Above this, a size change was *chosen* rather than dragged. The
    /// smallest gap between two presets is 0.2 and a drag tick is a fraction
    /// of a percent, so there is a wide margin either way.
    private static let steppedScaleDelta: CGFloat = 0.05

    /// The window is re-laid out at most this often while a drag is in
    /// flight. The panel is larger than the notch by the whole tooltip slack,
    /// so it can be a tenth of a second out of date without anything showing.
    private static let relocateInterval: TimeInterval = 0.1

    /// Resize the window on a budget, and always once the drag has stopped.
    private func coalesceRelocate() {
        let now = Date()
        if now.timeIntervalSince(lastRelocate) >= Self.relocateInterval {
            lastRelocate = now
            relocate()
            return
        }
        // Too soon. Replace any pending catch-up with one scheduled from now,
        // so a drag that stops mid-interval still ends up correctly sized.
        pendingRelocate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastRelocate = Date()
            self.relocate()
            self.updateInteractiveRects()
        }
        pendingRelocate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relocateInterval,
                                      execute: work)
    }

    private var lastRelocate = Date.distantPast
    private var pendingRelocate: DispatchWorkItem?
    func apply(edge: NotchEdge) {
        guard model.edge != edge else { return }
        guard let panel else {   // before there is anything on screen to fade
            model.edge = edge
            relocate()
            return
        }

        let wasOpen = model.isExpanded
        model.hoveredIndex = nil
        setPointing(false)

        // Clicking through the picker starts a move before the last one has
        // landed, and a stale completion would drop the notch on an edge the
        // user has already moved on from.
        edgeChange += 1
        let change = edgeChange

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.edgeCrossfade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, change == self.edgeChange else { return }

                // Land folded, and at full strength: the opening *is* the
                // animation, and fading in underneath it would be two at once.
                self.model.edge = edge
                self.model.isExpanded = false
                self.relocate()
                self.updateInteractiveRects()
                panel.alphaValue = 1

                guard wasOpen else { return }
                // A beat, then open. Not decoration: setting it shut and open
                // again inside one turn lets SwiftUI coalesce the pair, and the
                // notch arrives at full size having animated nothing.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalBeat) {
                    MainActor.assumeIsolated {
                        guard change == self.edgeChange else { return }
                        withAnimation(NotchMotion.unfold) { self.model.isExpanded = true }
                        // The panel too. The relocate above ran while the notch
                        // was folded, and opening it here without another one
                        // left the window at the folded size: the shape centres
                        // on the panel it is in, so it sat some 19pt left of
                        // where the settings orb and the tooltip — both placed
                        // from `slack` — expected it. That is the arc drifting
                        // off the corner and the card pointing wide of its ring
                        // after an edge change, and only after one.
                        self.relocate()
                        self.updateInteractiveRects()
                    }
                }
            }
        }
    }

    func apply(displayPreference: DisplayPreference) {
        guard self.displayPreference != displayPreference else { return }
        self.displayPreference = displayPreference
        relocate()
    }

    /// Half the crossing, each way. Short: it is a settings change, not a
    /// flourish, and the notch should be back before you have looked up.
    private static let edgeCrossfade: TimeInterval = 0.16
    /// The pause between landing and opening.
    private static let arrivalBeat: TimeInterval = 0.05
    private var edgeChange = 0

    func apply(_ visibility: NotchVisibility) {
        self.visibility = visibility
        // A standing choice outranks a peek that happens to be in flight.
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        switch visibility {
        case .alwaysShow:
            if !Runtime.isUnderTest { panel?.orderFrontRegardless() }
            // Any pin made by hand is subsumed by the setting, exactly as it is
            // for the other two. Leaving it set would hold `handleActiveSpaceOrAppChange`
            // off for the rest of the session, so a pin made in hover mode would
            // silently disable the full-screen fold once Always show was chosen.
            model.isPinned = false
            model.isAlwaysOn = true
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        case .onHover:
            if !Runtime.isUnderTest { panel?.orderFrontRegardless() }
            model.isPinned = false
            model.isAlwaysOn = false
            // Fold now rather than waiting for the pointer to leave: it may
            // already be somewhere else, in which case nothing would arrive to
            // close it and "on hover" would look exactly like "always show".
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
        case .hidden:
            model.isPinned = false
            model.isAlwaysOn = false
            model.isExpanded = false
            model.hoveredIndex = nil
            // Ordered out rather than made transparent. An invisible panel that
            // still takes the screen edge would keep swallowing the pointer.
            panel?.orderOut(nil)
        }
        setPointing(false)
        updateInteractiveRects()
    }

    // MARK: - Peeking

    /// Open the notch by itself for a moment, because something happened.
    ///
    /// Distinct from `setExpanded(true)`, which is the pointer arriving: this
    /// has no pointer to leave again, so it schedules its own close. The close
    /// checks the same two conditions the hover fold does — pinned open, or the
    /// pointer now resting on it — because a peek that arrives while you are
    /// already reading the notch must not yank it shut underneath you.
    ///
    /// `pid` is the agent's process, used only if the peek is clicked; nil
    /// leaves the click doing what it ordinarily does.
    func peek(for duration: TimeInterval, focusing pid: pid_t?) {
        // Hidden is a standing choice that the notch is not to be on screen.
        // Something finishing is not grounds to overrule it — the chime still
        // sounds, which is the part that works with nothing visible.
        guard visibility != .hidden, let panel else {
            Log.usage.debug("peek skipped: notch hidden")
            return
        }
        Log.usage.debug("peek for \(duration, privacy: .public)s, pid \(pid ?? -1, privacy: .public)")

        if let pid {
            pendingFocus = (pid: pid, until: Date().addingTimeInterval(duration + Self.focusGrace))
        }
        peekUntil = Date().addingTimeInterval(duration)

        if !Runtime.isUnderTest { panel.orderFrontRegardless() }
        foldWork?.cancel()
        foldWork = nil
        peekWork?.cancel()
        withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        updateInteractiveRects()

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.peekWork = nil
                self.peekUntil = nil
                let stillHoldsOpen = self.model.isPinned || (self.model.isAlwaysOn && !(self.foldsForFullScreen && self.isFullScreenActive()))
                guard !stillHoldsOpen else { return }
                // Left open if the peek did its job and the pointer is already
                // there; the ordinary hover fold takes it from here.
                guard !self.liveRect.contains(self.localCursor(in: panel.frame)) else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
                Log.usage.debug("peek folded")
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Open the notch and show a usage reset notification modal card.
    ///
    /// Returns whether the card was actually shown: a hidden notch has nowhere
    /// to put it, and the caller owes the user another way of hearing about it.
    @discardableResult
    func showResetAlert(_ event: UsageResetEvent, duration: TimeInterval = 5.0) -> Bool {
        guard visibility != .hidden, let panel else {
            Log.usage.debug("reset alert skipped: notch hidden")
            return false
        }
        model.activeResetAlert = event
        peek(for: duration, focusing: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.activeResetAlert == event {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.model.activeResetAlert = nil
                    }
                    self.updateInteractiveRects()
                }
            }
        }
        return true
    }

    /// How long after a peek folds a click still counts as answering it. Covers
    /// the reach for the mouse that started while the notch was still open.
    private static let focusGrace: TimeInterval = 2

    /// Raise the terminal the peeked session is running in, if the offer stands.
    private func takePendingFocus() -> Bool {
        guard let pending = pendingFocus, pending.until > Date() else {
            pendingFocus = nil
            return false
        }
        pendingFocus = nil
        // The same exact-tab jump a session row gives, not just the app.
        Task { _ = await SessionFocus.focus(pid: pending.pid) }
        return true
    }

    /// Tear down a controller whose display is gone: hide first so no panel
    /// lingers on a screen that no longer exists, then stop its timers and
    /// monitors — a retired controller that kept polling would relocate
    /// another display's panel underneath a parked pointer.
    func retire() {
        apply(.hidden)
        stop()
    }

    /// Clicking the open notch pins it, so it stays put while you read it.
    func togglePinned() {
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        }
        updateInteractiveRects()
    }

    /// Which ring a point along the panel is on.
    ///
    /// The copy that carries the readings, and only that one: the mirror is the
    /// container with nothing in it, so there is nothing on it to point at.
    func cellIndex(along: CGFloat) -> Int? {
        let wing = model.cellWing
        guard model.alongWithin(along, of: wing) != nil else { return nil }
        let pitch = model.cellPitch * model.sizeScale
        for index in model.snapshots.indices {
            let centre = model.ringAlong(index: index, in: wing)
            if abs(along - centre) <= pitch / 2 { return index }
        }
        return nil
    }

    // MARK: - Odds and ends

    private func startClock() {
        // Keeps "Resets in N min" from going stale while the tooltip is open.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func contextMenu() -> NSMenu {
        Log.usage.debug("context menu opened")
        let menu = NSMenu()
        // AppKit otherwise decides enablement itself and overrules the line
        // below. Turning it off means every item has to say so for itself.
        menu.autoenablesItems = false
        let keepOpen = NSMenuItem(
            title: L10n.t("Keep open"),
            action: #selector(MenuActions.togglePinned(_:)),
            keyEquivalent: model.isPinned ? "✓" : ""
        )
        keepOpen.keyEquivalentModifierMask = []
        keepOpen.target = menuActions
        keepOpen.isEnabled = true
        menu.addItem(keepOpen)
        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: L10n.t("Refresh now"),
            action: #selector(MenuActions.refreshNow(_:)),
            keyEquivalent: "r"
        )
        refresh.target = menuActions
        refresh.isEnabled = true
        menu.addItem(refresh)

        for (index, entry) in signInItems.enumerated() {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(MenuActions.signIn(_:)),
                keyEquivalent: ""
            )
            item.target = menuActions
            item.tag = index
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.t("Quit Codenotch"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ).isEnabled = true
        return menu
    }

    private lazy var menuActions = MenuActions(
        refresh: { [weak self] in self?.onRefresh?() },
        signIn: { [weak self] index in self?.signInItems[safe: index]?.action() },
        togglePinned: { [weak self] in self?.togglePinned() }
    )
}


/// A menu item needs an Objective-C target, which a `@MainActor` Swift class
/// with closures cannot be directly.
final class MenuActions: NSObject {
    private let refresh: () -> Void
    private let signIn: (Int) -> Void
    private let pin: () -> Void

    init(
        refresh: @escaping () -> Void,
        signIn: @escaping (Int) -> Void,
        togglePinned: @escaping () -> Void
    ) {
        self.refresh = refresh
        self.signIn = signIn
        self.pin = togglePinned
    }

    @objc func refreshNow(_ sender: Any?) { refresh() }
    @objc func togglePinned(_ sender: Any?) { pin() }

    @objc func signIn(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        signIn(item.tag)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Receives a display link's ticks for something that is not an `NSObject`.
final class DisplayTick: NSObject {
    private let action: (CADisplayLink) -> Void
    init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
    @objc func tick(_ link: CADisplayLink) { action(link) }
}
