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

    /// White for working, deliberately: the indicator sits inside a ring whose
    /// colour already means "how much of your limit is gone", and a neutral
    /// tone cannot be misread as part of that scale. Waiting gets amber because
    /// it is the one state that wants something from you.
    var color: Color {
        switch state {
        case .working: return Palette.textPrimary
        case .waiting: return Palette.watch
        case .success: return Palette.ample
        case .idle:    return Palette.ringTrack
        }
    }

    var waitingSessions: [AgentSession] { sessions.filter { $0.state == .waiting } }

    /// Idle this long and a session is folded into one "N idle" line: it is
    /// still open, but no longer news, and ten of them drowned the one asking
    /// for you.
    static let idleFoldAfter: TimeInterval = 10 * 60

    private func isFolded(_ session: AgentSession, now: Date) -> Bool {
        session.state == .idle && now.timeIntervalSince(session.since) >= Self.idleFoldAfter
    }

    /// The sessions that get a row of their own.
    /// `showingIdle` is the "N idle" line having been clicked open: every
    /// session gets a row until the tooltip closes.
    func listedSessions(now: Date, showingIdle: Bool = false) -> [AgentSession] {
        showingIdle ? sessions : sessions.filter { !isFolded($0, now: now) }
    }
    /// How many would fold — counted whether or not they are showing, since
    /// the line that folds them back needs to exist either way.
    func foldedIdleCount(now: Date) -> Int { sessions.filter { isFolded($0, now: now) }.count }

    /// The rows the tooltip draws, in order: waiting first, so what the cap
    /// hides is what matters least. Shared by the card that draws them and the
    /// controller that hit-tests them, so the two can never disagree.
    func shownSessions(now: Date, cap: Int, showingIdle: Bool = false) -> [AgentSession] {
        let groups = sessionGroups(now: now, cap: cap, showingIdle: showingIdle)
        return groups.active + groups.idle
    }

    /// The list as it is drawn: the active rows, then — when any have folded —
    /// the "N idle" / "Hide idle" header with the idle rows under it, then an
    /// "and N more" line for whatever the cap left out. The cap counts rows
    /// from the top, so active sessions are the last to be cut.
    struct SessionGroups: Equatable {
        var active: [AgentSession]
        /// Rows under the header; empty while the group is folded.
        var idle: [AgentSession]
        /// How many sessions the header folds, whether or not they are showing.
        var folded: Int
        /// Rows left out for want of room.
        var more: Int
        var hasHeader: Bool { folded > 0 }
    }

    func sessionGroups(now: Date, cap: Int, showingIdle: Bool = false) -> SessionGroups {
        let rank: (AgentSession) -> Int = {
            switch $0.state { case .waiting: 0; case .busy: 1; case .success: 2; case .idle: 3 }
        }
        let order: (AgentSession, AgentSession) -> Bool = { a, b in
            rank(a) == rank(b) ? a.since > b.since : rank(a) < rank(b)
        }
        let listed = listedSessions(now: now).sorted(by: order)
        let folded = sessions.filter { isFolded($0, now: now) }.sorted(by: order)
        let candidates = listed.count + (showingIdle ? folded.count : 0)
        func fill(_ room: Int) -> SessionGroups {
            let active = Array(listed.prefix(room))
            let idle = showingIdle ? Array(folded.prefix(room - active.count)) : []
            return SessionGroups(active: active, idle: idle, folded: folded.count,
                                 more: candidates - active.count - idle.count)
        }
        let groups = fill(max(0, cap))
        // The header and "and N more" would be two lines where the card has
        // budgeted one; a row is taller than a line, so giving one up fits.
        return groups.hasHeader && groups.more > 0 ? fill(max(0, cap - 1)) : groups
    }
}
