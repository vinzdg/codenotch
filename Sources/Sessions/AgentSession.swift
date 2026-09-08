import Foundation

/// One agent session, whichever tool it belongs to.
///
/// Deliberately a *display* model rather than a mirror of any one tool's file
/// format: Claude Code publishes a session registry, Cursor keeps composer rows
/// in SQLite, and neither shape belongs in the notch. Each monitor does its own
/// parsing and hands back this.
struct AgentSession: Identifiable, Equatable {
    /// What the session is doing right now.
    enum State: Equatable {
        case busy
        case waiting
        case idle
    }

    /// Where this session is running, so clicking it can focus the host app.
    enum FocusTarget: Equatable {
        case process(pid_t)
        case application(bundleID: String)
    }

    let id: String
    /// What to call it in the tooltip.
    let name: String
    /// The quieter second line — where it is running, or what it is doing.
    let detail: String
    let state: State
    /// Set while `waiting`: what it wants from you.
    let waitingFor: String?
    /// When it entered its current state.
    let since: Date
    /// Where to direct focus when clicked.
    let focusTarget: FocusTarget?

    init(
        id: String,
        name: String,
        detail: String,
        state: State,
        waitingFor: String?,
        since: Date,
        focusTarget: FocusTarget? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.waitingFor = waitingFor
        self.since = since
        self.focusTarget = focusTarget
    }
}
