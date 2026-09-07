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

    private(set) var scope: NotchScreenScope
    private var edge: NotchEdge
    private var visibility: NotchVisibility = .onHover
    private var snapshots: [ProviderSnapshot] = []
    private var refreshing: Set<String> = []
    private var sessions: [String: [AgentSession]] = [:]

    /// Hooked up by the app delegate; driven by the notch's own chrome.
    var onRefresh: (() -> Void)?
    var onRefreshProvider: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var signInItems: [(title: String, action: () -> Void)] = []

    /// What the fleet settled on, for tests that need to see panels come and
    /// go rather than take our word for it.
    var controllersForTesting: [NotchWindowController] { Array(controllers.values) }

    init(scope: NotchScreenScope, edge: NotchEdge) {
        self.scope = scope
        self.edge = edge
    }

    func show() {
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

    // MARK: - Readings

    func setSnapshots(_ snapshots: [ProviderSnapshot]) {
        self.snapshots = snapshots
        let now = Date()
        for controller in controllers.values {
            withAnimation(NotchMotion.unfold) {
                controller.model.snapshots = snapshots
            }
            controller.model.now = now
        }
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
            desired = NotchGeometry.preferredScreen(from: screens).map { [$0] } ?? []
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
            if let main = NotchGeometry.preferredScreen(from: screens) {
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
        controller.model.edge = edge
        controller.onRefresh = onRefresh
        controller.onRefreshProvider = onRefreshProvider
        controller.onOpenSettings = onOpenSettings
        controller.signInItems = signInItems
        controller.model.snapshots = snapshots
        controller.model.refreshing = refreshing
        controller.model.sessions = sessions
        controller.model.now = Date()
        controller.apply(visibility)
        controller.show()
        return controller
    }
}
