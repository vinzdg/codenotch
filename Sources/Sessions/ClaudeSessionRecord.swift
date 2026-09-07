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
    let session: AgentSession

    /// Decoded leniently on purpose: the file is written by another program on
    /// its own release schedule, and an unknown field must never cost us a
    /// session we could have shown.
    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let cwd = json["cwd"] as? String else { return nil }

        let raw = json["status"] as? String
        let tempo = json["tempo"] as? String        // the normalised form, when present
        let state: AgentSession.State
        switch (tempo, raw) {
        case ("blocked", _), (_, "waiting"): state = .waiting
        case ("active", _), (_, "busy"):     state = .busy
        default:                             state = .idle
        }

        let millis = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (json["updatedAt"] as? NSNumber)?.doubleValue

        self.pid = pid
        if let started = (json["startedAt"] as? NSNumber)?.doubleValue {
            self.startedAt = Date(timeIntervalSince1970: started / 1000)
        } else {
            self.startedAt = (json["procStart"] as? String).flatMap(Self.parseProcStart)
        }

        let folder = (cwd as NSString).lastPathComponent
        self.session = AgentSession(
            id: "claude.\(pid)",
            name: (json["name"] as? String) ?? folder,
            detail: "\(Self.surface(json["entrypoint"] as? String)) · \(folder)",
            state: state,
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
            processID: pid
        )
    }

    static func surface(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return "Desktop"
        case "claude-vscode":                       return "VS Code"
        case "local-agent":                         return "Agent"
        default:                                    return "Terminal"
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
