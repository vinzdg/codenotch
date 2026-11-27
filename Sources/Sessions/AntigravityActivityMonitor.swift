import Combine
import Foundation
import SQLite3

/// Notices when Antigravity is working.
///
/// Its transcripts are appended to as an agent runs, so a file written moments
/// ago is a turn in progress. The step statuses *in the transcript* cannot say
/// more — every one of them says `DONE`, because a step reaches it only once it
/// is finished, so a long model answer or a long command is silence there. The
/// transcript's tail still answers whose move it is: a question or an approval
/// the user owes, or a turn that has ended.
///
/// The CLI also keeps `conversations/<id>.db`, whose `steps.status` is written
/// while a step is in flight, so it answers what the transcript cannot: a tool
/// running, the model generating, a step waiting for permission. The editor
/// writes no such database, so for it recency remains the only signal.
///
/// Without this the Gemini ring never showed the working state that Claude,
/// Cursor and Codex all had, and the store never learned Antigravity was busy,
/// so it stayed on its slow idle poll while usage was actively being spent.
final class AntigravityActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let roots: [URL]
    private let interval: TimeInterval
    /// How recently a transcript must have been written to count as live.
    /// Generous, because a model can think for a while between two lines.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    /// How long a step in flight is believed through transcript silence. A
    /// hard-killed `agy` leaves its row at 2 or 8 for good (SIGTERM was seen to
    /// set 6), so this is the crash guard; of 1029 in-turn gaps measured this
    /// month, three were longer than ten minutes.
    static let liveStepWindow: TimeInterval = 600

    init(roots: [URL] = AntigravityActivity.transcriptRoots,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 45) {
        self.roots = roots
        self.interval = interval
        self.staleAfter = staleAfter
    }

    convenience init(profile: AntigravityProfile,
                     interval: TimeInterval = 2,
                     staleAfter: TimeInterval = 45) {
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        self.init(roots: roots, interval: interval, staleAfter: staleAfter)
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let found = Self.read(roots: roots, staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    /// The most recent turn across every install — the same reasoning as
    /// `AntigravityActivity.transcriptRoots`. Watching one directory meant the
    /// ring never span for anyone whose Antigravity wrote to another.
    static func read(roots: [URL], staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        // A turn paid for by an API key is the Gemini API ring's, and one turn must not spin two rings.
        roots
            .filter { !AntigravityCLIGeminiUsage.usesAPIKey(store: $0.deletingLastPathComponent()) }
            .flatMap { read(root: $0, staleAfter: staleAfter, now: now) }
            .max { $0.since < $1.since }
            .map { [$0] } ?? []
    }

    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        guard let trajectories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var newest: (url: URL, modified: Date)?
        // Parallel sessions: one still working must not hide behind a newer
        // conversation that has just finished.
        var recent: [(url: URL, modified: Date)] = []
        for trajectory in trajectories {
            // String path, not `appendingPathComponent`: that constructor
            // touches the filesystem per call, which is one syscall too many
            // in a loop over every conversation ever written, on every tick.
            // The same goes for `attributesOfItem`, which pulls every
            // extended attribute along with the date — `stat` is the one
            // syscall that answers this.
            let transcriptPath = trajectory.path
                + "/.system_generated/logs/transcript.jsonl"
            var info = stat()
            guard stat(transcriptPath, &info) == 0 else { continue }
            let modified = Date(timeIntervalSince1970:
                TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            let entry = (url: URL(fileURLWithPath: transcriptPath), modified: modified)
            if now.timeIntervalSince(modified) <= liveStepWindow {
                recent.append(entry)
            }
            if newest == nil || modified > newest!.modified {
                newest = entry
            }
        }

        guard let newest else { return [] }
        let latest = session(trajectory: newest.url, modified: newest.modified,
                             staleAfter: staleAfter, now: now)
        if let latest, latest.state == .busy || latest.state == .waiting {
            return [latest]
        }

        // Another conversation counts only on its database's word: its tail
        // is older than the newest one's, and recency alone would be a guess.
        let others = recent
            .filter { $0.url.path != newest.url.path }
            .sorted { $0.modified > $1.modified }
        for other in others {
            guard let live = liveSteps(forTranscript: other.url) else { continue }
            if live.waiting {
                return [makeSession(trajectory: other.url, modified: other.modified,
                                    state: .waiting, waitingFor: L10n.t("Permission"))]
            }
            if live.working {
                return [makeSession(trajectory: other.url, modified: other.modified,
                                    state: .busy, waitingFor: nil)]
            }
        }
        return latest.map { [$0] } ?? []
    }

    /// What the CLI's conversation database says is in flight, beside the
    /// transcript at `store/brain/<id>/.system_generated/logs/transcript.jsonl`.
    ///
    /// `steps.status`, observed on agy 1.5.18: 3 done, 7 error, 6 cancelled,
    /// 2 a tool step running, 8 the model generating, 9 a tool step waiting for
    /// the user's approval. `nil` when there is no readable database, which is
    /// always the case for the editor's stores.
    static func liveSteps(forTranscript trajectory: URL) -> (waiting: Bool, working: Bool)? {
        let conversation = trajectory.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let store = conversation.deletingLastPathComponent().deletingLastPathComponent()
        let url = store.appendingPathComponent("conversations/\(conversation.lastPathComponent).db")
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        let statuses = SQLiteStore.rows(in: db, sql: "SELECT DISTINCT status FROM steps WHERE status IN (2, 8, 9)")
        return (waiting: statuses.contains("9"),
                working: statuses.contains("2") || statuses.contains("8"))
    }

    static func tail(of url: URL, bytes: Int = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    static func parseState(inTail data: Data) -> (state: AgentSession.State, waitingFor: String?) {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        
        var isTurnOver = false
        // A record newer than the newest model answer: a tool result or a system
        // message. Held rather than answered at once, because what it means depends
        // on the call before it — after `finish` it closes the turn, after anything
        // else the turn is still running.
        var sawLaterRecord = false

        for line in lines.reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "USER_INPUT" {
                return isTurnOver ? (.idle, nil) : (.busy, nil)
            } else if type == "PLANNER_RESPONSE" {
                let toolCalls = json["tool_calls"] as? [[String: Any]] ?? []
                if toolCalls.contains(where: { $0["name"] as? String == "finish" }) {
                    // How a sub-agent hands back: a tool call, so it looked like work in progress.
                    isTurnOver = true
                } else if sawLaterRecord && !isTurnOver {
                    return (.busy, nil)
                } else if toolCalls.isEmpty {
                    isTurnOver = true
                } else {
                    for call in toolCalls {
                        guard let name = call["name"] as? String else { continue }
                        if name.contains("ask_question") {
                            return (.waiting, L10n.t("Question"))
                        }
                        if name.contains("multi_replace_file_content") || name.contains("write_to_file") || name.contains("replace_file_content") {
                            if let args = call["arguments"] as? [String: Any],
                               let meta = args["ArtifactMetadata"] as? [String: Any],
                               meta["RequestFeedback"] as? Bool == true {
                                return (.waiting, L10n.t("Approval"))
                            }
                        }
                    }
                    if !isTurnOver { return (.busy, nil) }
                }
            } else if type == "EPHEMERAL_MESSAGE" || type == "CONVERSATION_HISTORY" || type == "KNOWLEDGE_ARTIFACTS" || type == "CHECKPOINT" {
                continue
            } else if !isTurnOver {
                sawLaterRecord = true
            }
        }

        return sawLaterRecord && !isTurnOver ? (.busy, nil) : (.idle, nil)
    }

    /// Only a transcript written within the window counts. An older one is a
    /// finished turn, and showing it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        trajectory: URL, modified: Date, staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        var (state, waitingFor) = tail(of: trajectory).map(parseState(inTail:)) ?? (.idle, nil)

        let live = liveSteps(forTranscript: trajectory)
        if live?.waiting == true {
            // A step awaiting approval is never in the transcript; a tail that
            // already names a Question or an Approval keeps its own label.
            if state != .waiting {
                state = .waiting
                waitingFor = L10n.t("Permission")
            }
        } else if live?.working == true {
            // Covers a command moved to the background, whose transcript reads
            // as a finished turn, and a question that has just been answered.
            state = .busy
            waitingFor = nil
        }

        let age = now.timeIntervalSince(modified)

        if state == .idle {
            if age <= 9 {
                state = .success
            } else {
                return nil
            }
        } else if state == .busy {
            // Fallback timeout for busy state, just in case the file stops updating
            // due to a crash but the state didn't become idle.
            guard age <= (live?.working == true ? liveStepWindow : staleAfter + 15) else { return nil }
        }
        // If state == .waiting, we do not expire it, it remains indefinitely.

        return makeSession(trajectory: trajectory, modified: modified,
                           state: state, waitingFor: waitingFor)
    }

    private static func makeSession(
        trajectory: URL, modified: Date, state: AgentSession.State, waitingFor: String?
    ) -> AgentSession {
        // The trajectory's own directory names it; the file is always
        // `transcript.jsonl`.
        let id = trajectory.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            
        let detail: String
        switch state {
        case .busy: detail = L10n.t("Working")
        case .waiting: detail = waitingFor ?? L10n.t("Waiting")
        case .success: detail = L10n.t("Complete")
        case .idle: detail = L10n.t("Idle")
        }

        return AgentSession(
            id: "antigravity.\(id)",
            name: "Antigravity",
            detail: detail,
            state: state,
            waitingFor: waitingFor,
            since: modified
        )
    }
}
