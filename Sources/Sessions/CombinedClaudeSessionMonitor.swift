import Combine
import Foundation

/// Several `ClaudeSessionMonitor`s presented to the notch as one.
///
/// Two configuration directories signed into the same organization share a
/// limit, and so share a ring — see `ClaudeProfile.oneRingPerOrganization`.
/// Their sessions have to share it too. Keeping only the surviving directory's
/// monitor would leave work running in the merged one spinning nothing: a
/// quieter blind spot than the duplicate ring the merge removed, but a blind
/// spot in the same place, and harder to notice because the ring looks right.
///
/// Built only when a merge actually happened. One directory per organization —
/// which is every install that has not aliased a second login to the same
/// account — gets its `ClaudeSessionMonitor` directly, exactly as before.
@MainActor
final class CombinedClaudeSessionMonitor: AgentActivityMonitor {
    let monitors: [ClaudeSessionMonitor]

    init(_ monitors: [ClaudeSessionMonitor]) {
        self.monitors = monitors
    }

    /// Every directory's sessions, the surviving profile's own first.
    ///
    /// Not deduplicated. A session is a pid in one directory's registry, and no
    /// pid is in two of them — `ClaudeSessionMonitor.deduplicated` exists for
    /// the same session appearing twice *within* one registry, which is a
    /// different problem and already handled a level down.
    var sessions: [AgentSession] { monitors.flatMap(\.sessions) }

    /// Re-published on every change to any of them.
    ///
    /// `combineLatest` rather than `merge`: merge would emit one directory's
    /// array as though it were the whole ring's, so a session starting in the
    /// second directory would blank out the first. Each monitor publishes its
    /// current value on subscribe — they are `@Published` — so the combination
    /// delivers immediately rather than waiting for all of them to change once.
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> {
        monitors
            .map(\.sessionsPublisher)
            .reduce(Just([AgentSession]()).eraseToAnyPublisher()) { combined, next in
                combined.combineLatest(next) { $0 + $1 }.eraseToAnyPublisher()
            }
    }

    func start() { monitors.forEach { $0.start() } }
    func stop() { monitors.forEach { $0.stop() } }
}
