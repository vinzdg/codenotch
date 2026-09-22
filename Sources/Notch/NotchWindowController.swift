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
    /// A move settled on a new edge. The fleet owns writing that to
    /// preferences, for the same reason it owns `onReposition`.
    var onMoveToEdge: ((NotchEdge) -> Void)?

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
    private var foldWork: DispatchWorkItem?
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
    private var isPointing = false
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

        // The keyboard going elsewhere (a click in another app) ends any
        // typing in the card, whatever the field's focus state last said.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, (note.object as? NSWindow) === panel else { return }
                    if TodoStore.shared.editing { TodoStore.shared.editing = false }
                }
            }
            .store(in: &cancellables)

        // While a tasks field is being typed in the card holds still; once it
        // is done the pointer decides again, and the keyboard goes back.
        TodoStore.shared.$editing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] editing in
                MainActor.assumeIsolated {
                    guard let self, !editing else { return }
                    self.panel?.makeFirstResponder(nil)
                    self.cursorMoved()
                }
            }
            .store(in: &cancellables)

        // The tasks card changes shape on its own: "@" opens a list of
        // projects under the field, a tab has more rows, a focus block starts
        // or stops. None of that goes through the snapshots, so the panel is
        // re-measured here and the view told to draw again.
        Publishers.Merge4(
            TodoStore.shared.$layoutTick.map { _ in () }.eraseToAnyPublisher(),
            TodoStore.shared.$tab.map { _ in () }.eraseToAnyPublisher(),
            FocusStore.shared.$taskID.map { _ in () }.eraseToAnyPublisher(),
            FocusStore.shared.$isRunning.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.objectWillChange.send()
                self.relocate()
                self.updateInteractiveRects()
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

        // A model can gain speed rows without changing the cell count. Read
        // after Published's willSet so sizing sees the new card contents too.
        model.$snapshots
            .removeDuplicates()
            .receive(on: RunLoop.main)
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
            trailingExtent: model.trailingExtent,
            leadingExtent: model.leadingExtent
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
            panel.onDoubleClick = { [weak self] point in self?.handleDoubleClick(at: point) }
            panel.onDragStart = { [weak self] in self?.beginOptionDrag() }
            panel.onDrag = { [weak self] dx, dy in self?.dragged(dx: dx, dy: dy) }
            panel.onDragEnd = { [weak self] in
                guard let self else { return }
                self.onReposition?(self.model.alongOffset)
                self.endOptionDrag()
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
        model.alongOffset += model.edge.isVertical ? dy : dx
        relocate()
    }

    private func beginOptionDrag() {
        guard !isOptionDragging else { return }
        isOptionDragging = true
        clearHoverWork?.cancel()
        clearHoverWork = nil
        foldWork?.cancel()
        foldWork = nil
        model.hoveredIndex = nil
        model.isHoveringSettings = false
        model.isHoveringMove = false
        setPointing(false)
        updateInteractiveRects()
    }

    private func endOptionDrag() {
        guard isOptionDragging else { return }
        isOptionDragging = false
        cursorMoved()
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
            along: model.slack,
            across: 0,
            length: model.shapeLength * model.sizeScale,
            depth: model.notchDepth * model.sizeScale
        )
    }

    /// What wakes the folded notch. Larger than the pill it surrounds, and
    /// exactly the hardware notch when it is joined to one — see
    /// `NotchViewModel.wakeLength` for both halves of that.
    private var pillRect: CGRect {
        placement.rect(
            along: model.slack + (model.shapeLength * model.sizeScale - model.wakeLength) / 2,
            across: 0,
            length: model.wakeLength,
            depth: model.wakeDepth
        )
    }

    /// The handle's bounding box, for deciding whether the panel takes events
    /// at all. Whether a point is actually *on* the handle is a finer question
    /// than a box can answer — see `isOverHandle`.
    private var handleRect: CGRect {
        let side = NotchLayout.orbHotZone
        let boxes = (model.orbHandlePoints + model.moveHandlePoints).map { point -> CGRect in
            let centre = placement.point(along: model.slack + point.x * model.sizeScale,
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
            along: (placement.along(of: local) - model.slack) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    /// Whether the pointer is on the move handle, asked in the same notch-own
    /// measurements `isOverHandle` uses.
    private func isOverMoveHandle(_ local: CGPoint) -> Bool {
        model.isOnMoveHandle(
            along: (placement.along(of: local) - model.slack) / model.sizeScale,
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
        let cardHeight = snapshot.id == TasksProvider.providerID ? TasksCard.height() : NotchLayout.cardHeight(
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

    private func updateInteractiveRects() {
        var rects = [liveRect]
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
        // Typing in the tasks card: the pointer's wanderings do not fold it.
        // Reaching for another ring is not a wandering, though: that ends the
        // typing and the other card comes up as it always does.
        if TodoStore.shared.editing, panel.isKeyWindow {
            let onOtherRing = model.isExpanded && notchRect.contains(local)
                && cellIndex(along: placement.along(of: local)).map { index in
                    model.snapshots.indices.contains(index) && model.snapshots[index].id != TasksProvider.providerID
                } == true
            guard onOtherRing else { return }
            panel.makeFirstResponder(nil)
            TodoStore.shared.editing = false
        }
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

        let overHandle = model.isExpanded && isOverHandle(local)
        if model.isHoveringSettings != overHandle {
            model.isHoveringSettings = overHandle
        }
        let overMove = model.isExpanded && isOverMoveHandle(local)
        if model.isHoveringMove != overMove {
            model.isHoveringMove = overMove
        }
        setPointing(
            Self.wantsPointingHand(isExpanded: model.isExpanded, cellIndex: target)
                || overHandle || overMove
        )

        panel.allowsKeyboard = model.isExpanded
            && target.map { model.snapshots.indices.contains($0) && model.snapshots[$0].id == TasksProvider.providerID } == true
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
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            return
        }

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
                self.foldWork = nil
                let stillHoldsOpen = self.model.isPinned || (self.model.isAlwaysOn && !ignoresAlwaysOn)
                guard !stillHoldsOpen else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
    }

    /// The rings are buttons, so they should say so.
    static func wantsPointingHand(isExpanded: Bool, cellIndex: Int?) -> Bool {
        isExpanded && cellIndex != nil
    }

    /// Pushed and popped rather than `set`, so leaving restores whatever cursor
    /// the app underneath had chosen. Setting `.arrow` on the way out would
    /// stamp an arrow over someone else's text caret.
    private func setPointing(_ wanted: Bool) {
        guard wanted != isPointing else { return }
        isPointing = wanted
        if wanted {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// A click on a ring refetches that provider; a click anywhere else on the
    /// open notch pins it. The ring is the more specific target, so it wins.
    /// Two clicks on the Tasks ring open the list in the app that owns it.
    func handleDoubleClick(at locationInWindow: CGPoint) {
        guard let panel, model.isExpanded else { return }
        let local = CGPoint(x: locationInWindow.x, y: panel.frame.height - locationInWindow.y)
        guard notchRect.contains(local),
              let index = cellIndex(along: placement.along(of: local)),
              model.snapshots.indices.contains(index),
              model.snapshots[index].id == TasksProvider.providerID else { return }
        Tasks.open()
    }

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
        // The move handle is tested before the settings orb and the cells for
        // the same reason the orb is: it sits over the stack, and whichever
        // band is nearest would otherwise swallow the press.
        if model.isExpanded, isOverMoveHandle(local) {
            model.moveSpins += 1
            beginMove()
            return
        }
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
            return
        }
        togglePinned()
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
    /// Recomputes the click-through region at once. The handle's hit points
    /// vanish with it, but the window only learns which of its pixels take the
    /// mouse when those regions are rebuilt; without this the spot where the
    /// handle was would keep catching clicks until something else moved.
    func apply(showsMoveHandle: Bool) {
        guard model.showsMoveHandle != showsMoveHandle else { return }
        model.showsMoveHandle = showsMoveHandle
        updateInteractiveRects()
    }

    func apply(alongOffset: CGFloat) {
        guard model.alongOffset != alongOffset else { return }
        model.alongOffset = alongOffset
        relocate()
    }

    func apply(scale: CGFloat) {
        guard model.sizeScale != scale else { return }

        // A drag arrives as a stream of tiny deltas; a preset, or a switch
        // between the two controls, arrives as one large one.
        let isDrag = abs(scale - model.sizeScale) < Self.steppedScaleDelta

        // The drawn shape follows every tick — that part is a redraw and it is
        // cheap. Re-laying the *window* out is not: `relocate` recomputes the
        // panel size through `maxCardHeight` and the `sessionCap` search, then
        // asks the compositor to resize a full-height window. Sixty of those a
        // second is what makes a drag feel like it is pulling something heavy.
        model.sizeScale = scale
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

    private var dropZones: DropZoneOverlay?

    /// Carries the notch: raises the drop zones, follows the pointer until the
    /// button lifts, and hands the edge it landed on to `onMoveToEdge`.
    ///
    /// Driven from the pointer's own position rather than from drag deltas,
    /// because what is being chosen is a *place on the screen*, not a distance
    /// moved — and a press that never moves has to be able to end on the edge
    /// it started from without having accumulated anything.
    ///
    /// Blocks on the panel's event stream until mouse-up, the same AppKit
    /// pattern `NotchPanel.trackOptionDrag` uses.
    private func beginMove() {
        guard let panel, let screen = currentScreen() else { return }

        let overlay = DropZoneOverlay(screen: screen)
        dropZones = overlay
        model.isMoving = true
        // Starts on the edge it is already on, so releasing without moving is
        // a no-op rather than a jump to whichever edge the maths rounds to.
        model.moveTarget = model.edge
        overlay.show(target: model.edge,
                     restingDepth: model.restingDepth * model.sizeScale,
                     restingLength: model.shapeLength * model.sizeScale)

        defer {
            model.isMoving = false
            model.moveTarget = nil
            overlay.hide()
            dropZones = nil
        }

        while let event = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let local = overlay.localPoint(from: NSEvent.mouseLocation)
            let target = EdgeDropZones.edge(at: local, in: overlay.screenSize)

            switch event.type {
            case .leftMouseDragged:
                if model.moveTarget != target {
                    model.moveTarget = target
                }
                overlay.show(target: target,
                             restingDepth: model.restingDepth * model.sizeScale,
                             restingLength: model.shapeLength * model.sizeScale)
            case .leftMouseUp:
                if target != model.edge { onMoveToEdge?(target) }
                return
            default:
                return
            }
        }
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

    func cellIndex(along: CGFloat) -> Int? {
        let pitch = model.cellPitch * model.sizeScale
        for index in model.snapshots.indices {
            let centre = model.slack + model.ringCenter(index: index) * model.sizeScale
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
        let focus = NSMenuItem(title: L10n.t("Focus…"), action: #selector(TasksMenuActions.openFocus(_:)), keyEquivalent: "")
        focus.target = TasksMenuActions.shared
        focus.isEnabled = true
        menu.addItem(focus)
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
