import AppKit
import Combine
import SwiftUI

/// One notch per display: owns a `NotchWindowController` for each screen the
/// scope asks for and fans every reading, session and setting out to all of
/// them.
///
/// Each controller keeps its own model — hover, open state and screen size are
/// per-display facts, and sharing one model would unfold every notch when the
/// pointer reaches any of them. The fleet is the only thing that is shared: it
/// remembers the latest of everything so a controller created later (a display
/// plugged in at noon) starts with today's readings rather than empty rings.
@MainActor
final class NotchFleet {
    private var controllers: [NSNumber: NotchWindowController] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// A model with no panel: what the menu bar's menu reads. Fed everything
    /// the displays' models are fed, so a model's line there is decorated —
    /// speed, context, phase, today's tokens — exactly as its cell is.
    let menuModel = NotchViewModel()
    /// Every model a reading has to reach.
    private var models: [NotchViewModel] { [menuModel] + controllers.values.map(\.model) }

    private(set) var scope: NotchScreenScope
    private var edge: NotchEdge
    private var visibility: NotchVisibility = .onHover

    private var snapshots: [ProviderSnapshot] = []
    private(set) var thinkingModels: [String: Date] = [:]
    /// Per source, the way the view model keeps them: the Ollama relay and
    /// the LM Studio log each replace their own readings wholesale.
    private var performances: [String: [String: LocalModelPerformance]] = [:]
    private var localActivities: [String: LocalModelActivity] = [:]
    private var ledger = LocalTokenLedger()
    private var localMetricsEnabled = false

    func setLocalMetricsEnabled(_ enabled: Bool) {
        localMetricsEnabled = enabled
        if !enabled { performances[NotchViewModel.ollamaSource] = nil; thinkingModels = [:] }
        for model in models { model.setLocalMetricsEnabled(enabled) }
    }
    private var refreshing: Set<String> = []
    /// Exposed read-only rather than private: completion-watching needs the
    /// merged dict after a fan-out, the same way it read `controller.model
    /// .sessions` before there was more than one controller.
    private(set) var sessions: [String: [AgentSession]] = [:]
    /// Which display a single, unassigned controller should sit on. Only
    /// consulted by `.mainDisplay` — every controller under `.allDisplays`
    /// already has its own `assignedScreen`, which wins over this in
    /// `NotchWindowController.currentScreen()`.
    private var displayPreference: DisplayPreference = .followActiveWindow
    private var resetTimeFormat: ResetTimeFormat = .automatic
    private var accentColor: AccentColorChoice = .system
    private var watchLimit: Double = 0.50
    private var criticalLimit: Double = 0.70
    private var colorTransitionStyle: ColorTransitionStyle = .hardStep
    /// One choice for the whole fleet, like the edge and the size: a weekly
    /// ring on one display and not another would read as a bug.
    private var weeklyRing: WeeklyRing = .off
    private var weeklyRingDashed: Bool = false
    private var showsNotchReadings: Bool = true
    private var showsMoveHandle = true
    private var foldsForFullScreen = true
    private var surfaceStyle: NotchSurfaceStyle = .glass
    private var deepSeekPricingEnabled = true
    private var deepSeekPricingSchedule = DeepSeekPricing.Schedule.current
    /// The ⌥-drag nudge along the current edge. One value for the whole
    /// fleet, the same as `edge` itself — displays do not each get their own
    /// edge, so they do not each get their own nudge either.
    private var alongOffset: CGFloat = 0
    /// One size for the whole fleet, for the same reason the edge is: a notch
    /// that were larger on one display than another would read as a bug.
    private var scale: CGFloat = 1

    /// Hooked up by the app delegate; driven by the notch's own chrome.
    var onRefresh: (() -> Void)?
    var onRefreshProvider: ((String) async -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Also given to `menuModel`, which has no controller to copy it from:
    /// the Detail panel draws the same session rows the notch does, and a row
    /// that takes you to its terminal in one place must do it in both.
    var onFocusSession: ((pid_t) -> Void)? {
        didSet { menuModel.onFocusSession = onFocusSession }
    }
    var signInItems: [(title: String, action: () -> Void)] = []
    /// An ⌥-drag on any one panel settled at a new offset. Persisting it is
    /// Preferences' job, same division `apply(edge:)` already keeps.
    var onReposition: ((CGFloat) -> Void)?
    /// A move handle carried a notch to another edge. Persisting it is
    /// Preferences' job, the same division `onReposition` keeps.
    var onMoveToEdge: ((NotchEdge) -> Void)?

    /// What the fleet settled on, for tests that need to see panels come and
    /// go rather than take our word for it.
    var controllersForTesting: [NotchWindowController] { Array(controllers.values) }

    init(scope: NotchScreenScope, edge: NotchEdge) {
        self.scope = scope
        self.edge = edge
    }

    /// Guards `apply(scope:)`/`apply(displayPreference:)` from reconciling
    /// before `show()` ever has: either one can otherwise build the fleet's
    /// first (and, for `.mainDisplay`, only) controller using whatever the
    /// app delegate has assigned to `onOpenSettings`/`onRefreshProvider`/etc.
    /// *so far* — nil, if either is called before that wiring runs — and
    /// `reconcile`'s own "keep the existing controller, just move it" fast
    /// path never revisits a controller's callbacks once made. A controller
    /// built with every action wired to nothing looks, from the screen,
    /// identical to a working one: it still opens, its rings still draw, and
    /// nothing about it says why every click does nothing.
    private var hasShown = false

    func show() {
        hasShown = true
        reconcile(screens: NSScreen.screens)
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile(screens: NSScreen.screens)
            }
        }
        .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        for id in controllers.keys {
            controllers[id]?.retire()
        }
        controllers.removeAll()
    }

    // MARK: - Settings

    func apply(scope: NotchScreenScope) {
        self.scope = scope
        guard hasShown else { return }
        reconcile(screens: NSScreen.screens)
    }

    func apply(edge: NotchEdge) {
        self.edge = edge
        for controller in controllers.values {
            controller.apply(edge: edge)
        }
    }

    func apply(_ visibility: NotchVisibility) {
        self.visibility = visibility
        for controller in controllers.values {
            controller.apply(visibility)
        }
    }

    /// Only `.mainDisplay` has a single, unassigned controller for this to
    /// mean anything to — reconciling picks it a screen using the new
    /// preference the same way it does on a screen-parameter change.
    func apply(displayPreference: DisplayPreference) {
        self.displayPreference = displayPreference
        guard hasShown else { return }
        reconcile(screens: NSScreen.screens)
    }

    /// Fanned to `models`, not to the controllers alone: `menuModel` is what
    /// the menu bar's menu and its Detail panel read, and a reset worded one
    /// way in the notch and another way in Detail is two answers to one
    /// setting. The same goes for every apply below that writes a *model*
    /// property rather than rebuilding a panel.
    func apply(resetTimeFormat: ResetTimeFormat) {
        self.resetTimeFormat = resetTimeFormat
        for model in models {
            model.resetTimeFormat = resetTimeFormat
        }
    }

    func apply(showsMoveHandle: Bool) {
        self.showsMoveHandle = showsMoveHandle
        for controller in controllers.values {
            controller.apply(showsMoveHandle: showsMoveHandle)
        }
    }

    func apply(foldsForFullScreen: Bool) {
        self.foldsForFullScreen = foldsForFullScreen
        for controller in controllers.values {
            controller.apply(foldsForFullScreen: foldsForFullScreen)
        }
    }

    func apply(showsNotchReadings: Bool) {
        self.showsNotchReadings = showsNotchReadings
        // Through the controller, which relays the window out: this one
        // changes the ring's size and so the notch's own length.
        for controller in controllers.values {
            controller.apply(showsNotchReadings: showsNotchReadings)
        }
    }

    func apply(weeklyRingDashed: Bool) {
        self.weeklyRingDashed = weeklyRingDashed
        for model in models {
            model.weeklyRingDashed = weeklyRingDashed
        }
    }

    func apply(weeklyRing: WeeklyRing) {
        self.weeklyRing = weeklyRing
        for model in models {
            model.weeklyRing = weeklyRing
        }
    }

    /// The Watch and Critical thresholds from Appearance. One pair for every
    /// surface: the notch, and the Detail panel reading `menuModel`, colour a
    /// percentage by the same rule or they disagree about what is urgent.
    func apply(watchLimit: Double, criticalLimit: Double) {
        self.watchLimit = watchLimit
        self.criticalLimit = criticalLimit
        for model in models {
            model.watchLimit = watchLimit
            model.criticalLimit = criticalLimit
        }
    }

    func apply(colorTransitionStyle: ColorTransitionStyle) {
        self.colorTransitionStyle = colorTransitionStyle
        for controller in controllers.values {
            controller.model.colorTransitionStyle = colorTransitionStyle
        }
    }

    func apply(accentColor: AccentColorChoice) {
        self.accentColor = accentColor
        for model in models {
            model.accentColor = accentColor
        }
    }

    func apply(surfaceStyle: NotchSurfaceStyle) {
        self.surfaceStyle = surfaceStyle
        for controller in controllers.values {
            controller.model.surfaceStyle = surfaceStyle
        }
    }

    func apply(deepSeekPricingEnabled: Bool) {
        self.deepSeekPricingEnabled = deepSeekPricingEnabled
        for model in models {
            model.deepSeekPricingEnabled = deepSeekPricingEnabled
        }
    }

    func apply(deepSeekPricingSchedule: DeepSeekPricing.Schedule) {
        self.deepSeekPricingSchedule = deepSeekPricingSchedule
        for model in models {
            model.deepSeekPricingSchedule = deepSeekPricingSchedule
        }
    }

    func apply(alongOffset: CGFloat) {
        self.alongOffset = alongOffset
        for controller in controllers.values {
            controller.apply(alongOffset: alongOffset)
        }
    }

    /// Through `controller.apply(size:)` rather than by setting the model
    /// directly, because the panel has to be rebuilt around the new size —
    /// the same division `apply(edge:)` keeps.
    func apply(scale: CGFloat) {
        self.scale = scale
        for controller in controllers.values {
            controller.apply(scale: scale)
        }
    }

    // MARK: - Readings

    func setSnapshots(_ snapshots: [ProviderSnapshot]) {
        self.snapshots = snapshots
        let now = Date()
        for model in models {
            model.updateSnapshots(snapshots)
            model.now = now
        }
    }

    func setThinkingModels(_ thinking: [String: Date]) {
        thinkingModels = thinking
        for model in models {
            model.thinkingModels = thinking
        }
    }

    func setPerformances(_ measurements: [String: LocalModelPerformance],
                         source: String = NotchViewModel.ollamaSource) {
        performances[source] = measurements
        for model in models {
            model.updatePerformances(measurements, source: source)
        }
    }

    func setLocalActivities(_ activities: [String: LocalModelActivity]) {
        localActivities = activities
        for model in models {
            model.localActivities = activities
        }
    }

    func setLedger(_ ledger: LocalTokenLedger) {
        self.ledger = ledger
        for model in models {
            model.updateLedger(ledger)
        }
    }

    /// Opens every panel for a moment, because something happened — the same
    /// announcement on every display rather than only the one you happen to
    /// be looking at.
    func peek(for duration: TimeInterval, focusing pid: pid_t?) {
        for controller in controllers.values {
            controller.peek(for: duration, focusing: pid)
        }
    }

    /// Shows a usage reset notification modal on every panel.
    /// Returns whether at least one notch had somewhere to show the card. With
    /// every notch hidden the alert would otherwise vanish without a trace.
    @discardableResult
    func showResetAlert(_ event: UsageResetEvent, duration: TimeInterval = 5.0) -> Bool {
        var shown = false
        for controller in controllers.values {
            shown = controller.showResetAlert(event, duration: duration) || shown
        }
        return shown
    }

    func setRefreshing(_ ids: Set<String>) {
        self.refreshing = ids
        for controller in controllers.values {
            controller.model.refreshing = ids
        }
    }

    func setSessions(providerID id: String, sessions live: [AgentSession]) {
        sessions[id] = live
        let now = Date()
        menuModel.sessions[id] = live
        menuModel.now = now
        for controller in controllers.values {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                controller.model.sessions[id] = live
            }
            controller.model.now = now
        }
    }

    // MARK: - Reconciliation

    /// Which notch a screen is, stable across polls while it stays connected.
    ///
    /// Every real display reports an `NSScreenNumber`; the fallback derives one
    /// from the origin so a screen without a number still gets a notch rather
    /// than none — at worst it is re-created when it moves.
    ///
    /// Nonisolated: pure computation on its argument, safe to call from anywhere.
    nonisolated static func key(for screen: NSScreen) -> NSNumber {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number
        }
        let origin = screen.frame.origin
        return NSNumber(value: Int(origin.x) * 31 + Int(origin.y))
    }

    /// Pure, so the add/remove maths can be tested without any displays: which
    /// keys to retire and which to create, in a stable order.
    ///
    /// Nonisolated: pure computation on its arguments, safe to call from anywhere.
    nonisolated static func planReconciliation(
        current: Set<NSNumber>, desired: [NSNumber]
    ) -> (remove: [NSNumber], add: [NSNumber]) {
        let want = Set(desired)
        let remove = current.subtracting(want).sorted { $0.intValue < $1.intValue }
        var seen = Set<NSNumber>()
        let add = desired.filter { want.contains($0) && !current.contains($0) && seen.insert($0).inserted }
        return (remove, add)
    }

    /// Exposed so a test can drive the fleet against the real screen list.
    func reconcileForTesting() {
        reconcile(screens: NSScreen.screens)
    }

    private func reconcile(screens: [NSScreen]) {
        let desired: [NSScreen]
        switch scope {
        case .mainDisplay:
            desired = NotchGeometry.preferredScreen(from: screens, preference: displayPreference).map { [$0] } ?? []
        case .allDisplays:
            desired = screens
        }
        let keys = desired.map(Self.key)
        // Screen numbers are unique per display; if they ever are not, fall
        // back to a single notch rather than keying two panels as one.
        guard Set(keys).count == keys.count else {
            for id in controllers.keys {
                controllers[id]?.retire()
            }
            controllers.removeAll()
            if let main = NotchGeometry.preferredScreen(from: screens, preference: displayPreference) {
                controllers[Self.key(for: main)] = makeController(on: main)
            }
            return
        }
        // The common case — one notch following the menu-bar screen — keeps
        // its controller and moves it, the way a single panel always did,
        // instead of tearing a panel down and building another.
        if scope == .mainDisplay, controllers.count == 1,
           let screen = desired.first, let controller = controllers.values.first {
            controller.assignedScreen = screen
            controller.relocate()
            return
        }
        let plan = Self.planReconciliation(current: Set(controllers.keys), desired: keys)
        for id in plan.remove {
            controllers[id]?.retire()
            controllers[id] = nil
        }
        for (screen, id) in zip(desired, keys) where plan.add.contains(id) {
            controllers[id] = makeController(on: screen)
        }
    }

    /// A controller that starts where every other one already is: same edge,
    /// same readings, same open state — a display plugged in at noon must not
    /// open on empty rings.
    private func makeController(on screen: NSScreen) -> NotchWindowController {
        let controller = NotchWindowController()
        controller.assignedScreen = screen
        controller.displayPreference = displayPreference
        controller.foldsForFullScreen = foldsForFullScreen
        controller.model.edge = edge
        controller.model.alongOffset = alongOffset
        // Set before `show()`, so a display plugged in later builds its panel
        // at the current size rather than at medium and resizing a beat later.
        controller.prime(scale: scale)
        controller.model.resetTimeFormat = resetTimeFormat
        controller.model.accentColor = accentColor
        controller.model.watchLimit = watchLimit
        controller.model.criticalLimit = criticalLimit
        controller.model.colorTransitionStyle = colorTransitionStyle
        controller.model.weeklyRing = weeklyRing
        controller.model.weeklyRingDashed = weeklyRingDashed
        controller.model.showsNotchReadings = showsNotchReadings
        controller.model.showsMoveHandle = showsMoveHandle
        controller.model.surfaceStyle = surfaceStyle
        controller.model.deepSeekPricingEnabled = deepSeekPricingEnabled
        controller.model.deepSeekPricingSchedule = deepSeekPricingSchedule

        controller.onRefresh = onRefresh
        controller.onRefreshProvider = onRefreshProvider
        controller.onOpenSettings = onOpenSettings
        controller.model.onOpenSettings = onOpenSettings
        controller.model.onFocusSession = onFocusSession
        controller.onReposition = onReposition
        controller.onMoveToEdge = onMoveToEdge
        controller.signInItems = signInItems
        controller.model.updateSnapshots(snapshots)
        controller.model.thinkingModels = thinkingModels
        controller.model.localActivities = localActivities
        controller.model.setLocalMetricsEnabled(localMetricsEnabled)
        for (source, measurements) in performances {
            controller.model.updatePerformances(measurements, source: source)
        }
        controller.model.updateLedger(ledger)
        controller.model.refreshing = refreshing
        controller.model.sessions = sessions
        controller.model.now = Date()
        controller.apply(visibility)
        controller.show()
        return controller
    }
}
