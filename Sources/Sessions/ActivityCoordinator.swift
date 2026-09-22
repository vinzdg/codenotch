import Combine
import Foundation

/// Owns session-monitor lifetimes so disconnected providers neither scan for
/// sessions nor keep usage refreshes in the fast, busy cadence.
@MainActor
final class ActivityCoordinator {
    /// Not constant: a plugin registered while the app runs can bring its own
    /// activity monitor with it.
    private var monitors: [String: any AgentActivityMonitor]
    private let onSessions: (String, [AgentSession]) -> Void
    private var subscriptions: [String: AnyCancellable] = [:]
    private(set) var activeIDs: Set<String> = []
    /// The ids the caller last asked to have watched. Remembered so a monitor
    /// arriving later (a plugin) starts watching immediately if its id is on.
    private var enabledIDs: Set<String> = []

    init(monitors: [String: any AgentActivityMonitor],
         onSessions: @escaping (String, [AgentSession]) -> Void) {
        self.monitors = monitors
        self.onSessions = onSessions
    }

    /// Every monitor id currently known, including any registered at runtime.
    var monitorIDs: Set<String> { Set(monitors.keys) }

    var isBusy: Bool {
        activeIDs.contains { id in
            monitors[id]?.sessions.contains { $0.state == .busy } == true
        }
    }

    /// Attach a monitor under a provider id. Starts watching immediately when
    /// the id is enabled; a monitor replacing an existing one takes over its
    /// state either way.
    func setMonitor(_ monitor: any AgentActivityMonitor, for id: String) {
        if activeIDs.contains(id) {
            subscriptions.removeValue(forKey: id)?.cancel()
            monitors[id]?.stop()
            activeIDs.remove(id)
        }
        monitors[id] = monitor
        applyEnabled()
    }

    /// Detach a provider's monitor, if one was attached at runtime.
    func removeMonitor(for id: String) {
        guard monitors[id] != nil else { return }
        if activeIDs.contains(id) {
            activeIDs.remove(id)
            subscriptions.removeValue(forKey: id)?.cancel()
            monitors[id]?.stop()
            onSessions(id, [])
        }
        monitors.removeValue(forKey: id)
    }

    func setEnabled(_ enabled: Set<String>) {
        enabledIDs = enabled
        applyEnabled()
    }

    private func applyEnabled() {
        let wanted = enabledIDs.intersection(monitors.keys)
        for id in activeIDs.subtracting(wanted) {
            activeIDs.remove(id)
            subscriptions.removeValue(forKey: id)?.cancel()
            monitors[id]?.stop()
            onSessions(id, [])
        }
        for id in wanted.subtracting(activeIDs) {
            guard let monitor = monitors[id] else { continue }
            activeIDs.insert(id)
            subscriptions[id] = monitor.sessionsPublisher
                .receive(on: RunLoop.main)
                .sink { [weak self] sessions in
                    guard let self, self.activeIDs.contains(id) else { return }
                    self.onSessions(id, sessions)
                }
            monitor.start()
        }
    }

    func stop() { setEnabled([]) }
}
