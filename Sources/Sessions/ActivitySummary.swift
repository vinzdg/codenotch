import SwiftUI

/// What the activity cell shows: the state of every live session, reduced to
/// the one thing worth knowing at a glance.
struct ActivitySummary: Equatable {
    enum State: Equatable {
        case working
        case waiting
        case success
        case idle
    }

    let state: State
    let sessions: [AgentSession]
    /// Requests lined up behind the one running — a local runtime's queue.
    /// Zero for every cloud agent, which has no such line to report.
    let queued: Int
    /// What the tooltip's header says while this is going on, where a local
    /// runtime names the phase. Nil leaves the header to the session's name.
    let note: String?

    /// Nil when nothing is running — the cell disappears rather than sitting
    /// there saying nothing.
    init?(sessions: [AgentSession], queued: Int = 0, note: String? = nil) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
        self.queued = max(0, queued)
        self.note = note
        // Anything blocked on you outranks anything merely busy: it is the only
        // state where the notch is asking for something.
        if sessions.contains(where: { $0.state == .waiting }) {
            state = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            state = .working
        } else if sessions.contains(where: { $0.state == .success }) {
            state = .success
        } else {
            state = .idle
        }
    }

    /// One short word, for the tooltip.
    var label: String {
        switch state {
        case .working: return L10n.t("working")
        case .waiting: return L10n.t("waiting")
        case .success: return L10n.t("complete")
        case .idle:    return L10n.t("idle")
        }
    }

    /// The ring draws working either as the neutral arc, which uses this colour
    /// (the default), or as the brand-coloured `BusyWave` when the user chose
    /// the breathing disc in Settings. The neutral value stays off the green /
    /// amber / red that already means "how much of your limit is gone".
    /// Waiting keeps amber in both because it is the one state that wants
    /// something from you.
    var color: Color {
        switch state {
        case .working: return Palette.textPrimary
        case .waiting: return Palette.watch
        case .success: return Palette.ample
        case .idle:    return Palette.ringTrack
        }
    }

    var waitingSessions: [AgentSession] { sessions.filter { $0.state == .waiting } }
}
