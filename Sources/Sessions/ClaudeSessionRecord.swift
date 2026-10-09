import Foundation

/// One entry in `~/.claude/sessions/<pid>.json`, as Claude Code writes it.
///
/// Kept separate from `AgentSession` because it carries things only the Claude
/// monitor needs — the pid and process start time used to tell a live session
/// from a file a crashed one left behind.
struct ClaudeSessionRecord {
    let pid: Int32
    /// Roughly when the process started. Only used to notice a recycled pid.
    let startedAt: Date?
    /// The session's own id, which is what names its transcript.
    let sessionID: String?
    /// Where it is running. The transcript is filed under this.
    let cwd: String
    /// Whether the record said anything the monitor understands about what the
    /// session is doing.
    ///
    /// False for every session the Claude desktop app hosts: Claude Code fills
    /// `status` in from its terminal interface, which a desktop session does
    /// not have. That is the flag that sends the monitor to the transcript
    /// instead — see `ClaudeTranscript`.
    let reportsStatus: Bool
    /// How the session was started: `cli`, `claude-desktop`, `claude-vscode`…
    let entrypoint: String?
    /// The id the Claude desktop app knows this session by, present only on the
    /// sessions it hosts. It is what names the app's own record of the session,
    /// and that record is filed under the account uuid — which is the only way
    /// to tell which account a desktop session belongs to. See
    /// `ClaudeDesktopSessionIndex`.
    let hostSessionID: String?
    let session: AgentSession

    /// Whether the Claude desktop app is what started this session.
    ///
    /// `claude-desktop-3p` is the same app hosting a third-party agent; both
    /// carry a `hostSessionId` and both are filed by the app under an account.
    var isDesktopHosted: Bool {
        entrypoint == "claude-desktop" || entrypoint == "claude-desktop-3p"
    }

    /// Whether a program started this session rather than a person: the Agent
    /// SDK (`sdk-ts`, `sdk-py`), or the CLI's own non-interactive mode
    /// (`sdk-cli`), which is what `claude -p` registers as.
    var isFromSDK: Bool {
        entrypoint?.hasPrefix("sdk-") == true
    }

    /// Decoded leniently on purpose: the file is written by another program on
    /// its own release schedule, and an unknown field must never cost us a
    /// session we could have shown.
    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let cwd = json["cwd"] as? String else { return nil }

        let raw = json["status"] as? String
        let tempo = json["tempo"] as? String        // the normalised form, when present
        let state: AgentSession.State
        // `reportsStatus` is about whether the record *said* something, not
        // about what it said: a word neither of us knows is no more use than no
        // word at all, and both are better answered by the transcript.
        let reportsStatus: Bool
        switch (tempo, raw) {
        case ("blocked", _), (_, "waiting"): (state, reportsStatus) = (.waiting, true)
        case ("active", _), (_, "busy"):     (state, reportsStatus) = (.busy, true)
        case ("idle", _), (_, "idle"):       (state, reportsStatus) = (.idle, true)
        default:                             (state, reportsStatus) = (.idle, false)
        }

        let millis = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (json["updatedAt"] as? NSNumber)?.doubleValue

        let entrypoint = json["entrypoint"] as? String

        self.pid = pid
        self.sessionID = json["sessionId"] as? String
        self.cwd = cwd
        self.reportsStatus = reportsStatus
        self.entrypoint = entrypoint
        self.hostSessionID = json["hostSessionId"] as? String
        if let started = (json["startedAt"] as? NSNumber)?.doubleValue {
            self.startedAt = Date(timeIntervalSince1970: started / 1000)
        } else {
            self.startedAt = (json["procStart"] as? String).flatMap(Self.parseProcStart)
        }

        let folder = (cwd as NSString).lastPathComponent
        self.session = AgentSession(
            id: "claude.\(pid)",
            name: (json["name"] as? String) ?? folder,
            detail: "\(Self.surface(entrypoint)) · \(folder)",
            state: state,
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            // `startedAt` before the clock, because a desktop record carries
            // neither `statusUpdatedAt` nor `updatedAt` and `Date()` is a
            // different answer on every rescan — which makes the session look
            // changed twice a second and sets the notch animating over and
            // over. When the transcript is readable it replaces this anyway;
            // this is what holds still until it is.
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? self.startedAt ?? Date(),
            processID: pid
        )
    }

    /// The same session, in a state read from somewhere other than the record.
    ///
    /// `waitingFor` is dropped on purpose: the only states that reach here come
    /// from the transcript, and the transcript cannot see a permission prompt.
    /// The pid stays: the registry file still names the process to jump to.
    func session(state: AgentSession.State, since: Date) -> AgentSession {
        AgentSession(id: session.id, name: session.name, detail: session.detail,
                     state: state, waitingFor: nil, since: since,
                     processID: session.processID)
    }

    static func surface(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return L10n.t("Desktop")
        case "claude-vscode":                       return L10n.t("VS Code")
        case "local-agent":                         return L10n.t("Agent")
        default:                                    return L10n.t("Terminal")
        }
    }

    /// `procStart` looks like "Fri Aug 28 05:15:20 2026" — a ctime string, in
    /// **UTC**, with the day of month space-padded on single-digit days.
    static func parseProcStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: collapsed)
    }
}
