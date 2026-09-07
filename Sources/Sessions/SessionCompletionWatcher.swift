import Foundation

/// Notices the moment an agent stops working.
///
/// The monitors publish *what is true now*; nothing in them says what changed.
/// That difference is the whole event here — a session sitting at `idle` is
/// unremarkable, a session that was `busy` a second ago and is `idle` now is
/// the thing worth looking up for. So this keeps the previous state of every
/// session and reports only the crossings.
///
/// Pure and free of AppKit on purpose: it is the part with the edge cases, and
/// tests can drive it directly.
struct SessionCompletionWatcher {
    /// Why a session is being announced.
    enum Reason: Equatable {
        /// Ran to the end of its turn.
        case finished
        /// Stopped to ask something, and is waiting on an answer.
        case blocked
    }

    struct Event: Equatable {
        let session: AgentSession
        let reason: Reason
        /// Which provider's ring it belongs to, so the notch can point at it.
        let providerID: String
    }

    /// The last state seen for every session, keyed by provider and session id.
    private var previous: [String: AgentSession.State] = [:]
    /// Nothing is announced from the first reading.
    ///
    /// Every session already running when Codenotch launches arrives with no
    /// history, and treating that as a transition would ring once per session
    /// on every start — including a restart in the middle of the night after a
    /// Sparkle update. The first pass only records.
    private var hasSeeded = false

    /// Feed the monitors' current view; get back what just changed.
    mutating func absorb(_ sessions: [String: [AgentSession]]) -> [Event] {
        var current: [String: AgentSession.State] = [:]
        var events: [Event] = []

        for (providerID, live) in sessions {
            for session in live {
                let key = "\(providerID)\u{1}\(session.id)"
                current[key] = session.state
                guard hasSeeded, let was = previous[key] else { continue }
                guard let reason = Self.reason(from: was, to: session.state) else { continue }
                events.append(Event(session: session, reason: reason, providerID: providerID))
            }
        }

        // Sessions that vanished are dropped rather than announced. A session
        // file disappears when the process exits — often *while* it was busy,
        // because quitting Claude Code mid-turn is an ordinary thing to do —
        // and a chime for a window that is already gone points at nothing.
        previous = current
        hasSeeded = true
        // Newest first, so the one that just landed is the one a single click
        // reaches.
        return events.sorted { $0.session.since > $1.session.since }
    }

    /// Only leaving `busy` counts.
    ///
    /// `waiting` to `idle` is the tail of a question that was answered, and
    /// `idle` to `idle` is the steady state of a window nobody is using —
    /// neither is a piece of work ending.
    static func reason(from was: AgentSession.State, to now: AgentSession.State) -> Reason? {
        guard was == .busy else { return nil }
        switch now {
        case .idle:    return .finished
        case .waiting: return .blocked
        case .busy:    return nil
        }
    }
}
